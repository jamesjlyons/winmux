import BridgeCore
import BridgeProtocol
import Foundation
import WorkspaceCore
#if canImport(AppBundle)
import AppBundle
import AppKit
#endif

// NSXPC's remote proxy is thread-safe; the imported Objective-C protocol does
// not express that property to Swift's concurrency checker.
private final class BrowserOwnerProxy: @unchecked Sendable {
    let value: any WMBrowserSurfaceOwner
    init(_ value: any WMBrowserSurfaceOwner) { self.value = value }
}

final class SessionEndpoint: NSObject, WMWorkspaceBridge, @unchecked Sendable {
    private let session = BridgeSession()
    private let lock = NSLock()
    private var inventory = BrowserInventory()
    private var testStarted = false
    private var testOutcomes: [String: String] = [:]
    private var fullMessages = 0
    private var deltaMessages = 0
    private weak var connection: NSXPCConnection?
    private let testReport: URL?
    let connectionID = UUID()
    private let sidebarEnabled: Bool
    private var closed = false

    init(connection: NSXPCConnection, testReport: URL?, sidebarEnabled: Bool) {
        self.connection = connection
        self.testReport = testReport
        self.sidebarEnabled = sidebarEnabled
        super.init()
#if canImport(AppBundle)
        if sidebarEnabled {
            let id = connectionID, pid = connection.processIdentifier
            DispatchQueue.main.async { [self] in
                BrowserWorkspaceController.shared.connected(id, processID: pid) { [weak self] request, completion in
                    guard let self else { completion(.unavailable); return }
                    self.send(request, completion: completion)
                }
            }
        }
#endif
    }

    func invalidate() {
        lock.withLock {
            guard !closed else { return }
            closed = true
#if canImport(AppBundle)
            if sidebarEnabled {
                let id = connectionID
                DispatchQueue.main.async { BrowserWorkspaceController.shared.disconnected(id) }
            }
#endif
        }
    }

    @MainActor private func send(_ request: BrowserActionRequest,
                                completion: @escaping @MainActor (BrowserActionReply) -> Void) {
        guard !lock.withLock({ closed }), let connection,
              let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                  DispatchQueue.main.async { completion(.unavailable) }
              }) as? WMBrowserSurfaceOwner else { completion(.unavailable); return }
        proxy.performAction(request.action.rawValue, surface: request.surfaceID.description,
                            epoch: request.epoch.uuidString, operation: request.operation.uuidString,
                            revision: request.revision, generation: request.generation) { outcome in
            DispatchQueue.main.async { completion(BrowserActionReply(rawValue: outcome) ?? .invalidRequest) }
        }
    }

    func negotiateVersion(_ version: Int, reply: @escaping (Int, String?) -> Void) {
        let epoch = session.negotiate(version: version)
        reply(epoch == nil ? BridgeSession.version : version, epoch)
    }

    func pingEpoch(_ epoch: String, sequence: UInt64, reply: @escaping (Bool, UInt64) -> Void) {
        reply(session.accept(epoch: epoch, sequence: sequence), sequence)
    }

    func publishInventory(_ data: Data, epoch: String, sequence: UInt64, reply: @escaping (Bool, UInt64) -> Void) {
        let result = lock.withLock { () -> (Bool, UInt64, Bool) in
            guard !closed, data.count <= 1_048_576,
                  session.accept(epoch: epoch, sequence: sequence, minimumVersion: 2),
                  let message = try? JSONDecoder().decode(BrowserInventoryMessage.self, from: data),
                  inventory.apply(message) else { return (false, inventory.revision, false) }
            if message.full { fullMessages += 1 } else { deltaMessages += 1 }
#if canImport(AppBundle)
            if sidebarEnabled, let epochID = UUID(uuidString: epoch) {
                let snapshot = BrowserInventoryMessage(revision: inventory.revision, full: true, tabs: Array(inventory.tabs.values))
                let id = connectionID
                // Enqueue while holding the endpoint lock: invalidation cannot
                // overtake a validated update and resurrect disconnected rows.
                DispatchQueue.main.async { BrowserWorkspaceController.shared.received(snapshot, epoch: epochID, connection: id) }
            }
#endif
            let startTest = testReport != nil && !sidebarEnabled && !testStarted && inventory.tabs.count == 2
            if startTest { testStarted = true }
            return (true, inventory.revision, startTest)
        }
        reply(result.0, result.1)
        if testReport != nil {
            writeTestReport()
            if result.2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.exerciseActions(epoch: epoch) }
            }
        }
    }

    // Runs only in an explicitly named isolated test service. Production never
    // issues actions without a workspace user's request.
    private func exerciseActions(epoch: String) {
        guard let value = connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? WMBrowserSurfaceOwner else { return }
        let remote = BrowserOwnerProxy(value)
        let snapshot = lock.withLock { inventory }
        guard let id = snapshot.tabs.keys.sorted(by: { $0.description < $1.description }).first else { return }
        remote.value.performAction("focus", surface: id.description, epoch: epoch, operation: UUID().uuidString,
                             revision: snapshot.revision, generation: 2) { outcome in
            self.noteTest("focus", outcome)
            let fence = UUID().uuidString
            remote.value.performAction("cancel_focus", surface: "", epoch: epoch, operation: fence,
                                       revision: 0, generation: 3) { fenced in
                self.noteTest("native_focus_fence", fenced)
                remote.value.performAction("cancel_focus", surface: "", epoch: epoch, operation: fence,
                                           revision: 0, generation: 3) { repeated in
                    self.noteTest("repeated_fence", repeated)
                    remote.value.performAction("focus", surface: id.description, epoch: epoch, operation: UUID().uuidString,
                                         revision: snapshot.revision, generation: 1) { stale in
                        self.noteTest("stale_focus", stale)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            let revision = self.lock.withLock { self.inventory.revision }
                            let operation = UUID().uuidString
                            remote.value.performAction("close", surface: id.description, epoch: epoch, operation: operation,
                                                 revision: revision, generation: 0) { close in
                                self.noteTest("close", close)
                                remote.value.performAction("close", surface: id.description, epoch: epoch, operation: operation,
                                                     revision: revision, generation: 0) { repeated in
                                    self.noteTest("repeated_close", repeated)
                                    remote.value.performAction("close", surface: id.description + "x", epoch: epoch, operation: operation,
                                                               revision: revision, generation: 0) { conflict in
                                        self.noteTest("operation_conflict", conflict)
                                        remote.value.performAction("close", surface: id.description, epoch: UUID().uuidString,
                                                                   operation: UUID().uuidString, revision: revision, generation: 0) { stale in
                                            self.noteTest("foreign_epoch", stale)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func noteTest(_ action: String, _ outcome: String) {
        lock.withLock { testOutcomes[action] = outcome }
        writeTestReport()
    }

    private func writeTestReport() {
        guard let testReport else { return }
        lock.withLock {
            // Counts and outcomes only: no titles, URLs, profile paths or vault data.
            let report: [String: Any] = ["scope": "isolated_authenticated_inventory_actions", "revision": inventory.revision,
                                       "tab_count": inventory.tabs.count, "outcomes": testOutcomes,
                                       "full_messages": fullMessages, "delta_messages": deltaMessages]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) {
                try? data.write(to: testReport, options: .atomic)
            }
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let testReport: URL?
    let sidebarEnabled: Bool
    init(testReport: URL?, sidebarEnabled: Bool) { self.testReport = testReport; self.sidebarEnabled = sidebarEnabled }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: WMWorkspaceBridge.self)
        connection.remoteObjectInterface = NSXPCInterface(with: WMBrowserSurfaceOwner.self)
        let endpoint = SessionEndpoint(connection: connection, testReport: testReport, sidebarEnabled: sidebarEnabled)
        connection.exportedObject = endpoint
        connection.invalidationHandler = { [weak endpoint] in endpoint?.invalidate() }
        connection.interruptionHandler = { [weak endpoint] in endpoint?.invalidate() }
        connection.resume()
        return true
    }
}

do {
    let team = try SigningIdentity.ownTeamID()
    guard let requirement = SigningIdentity.requirement(identifier: SigningIdentity.browserID, teamID: team) else {
        throw NSError(domain: "WinMuxBrowser.Signing", code: 2)
    }
    var service = SigningIdentity.serviceName
    var testReport: URL?
    var sidebarEnabled = false
    var nativeState: URL?
    var nativeProcessID: Int32?
    let arguments = CommandLine.arguments
    if arguments.count > 1 {
        let prefix = SigningIdentity.serviceName + ".test."
        let nativeMode = (arguments.count == 5 || arguments.count == 7) && arguments[3] == "--manage-native"
        guard (arguments.count == 3 || (arguments.count == 4 && arguments[3] == "--sidebar-preview") || nativeMode), arguments[1].hasPrefix(prefix),
              UUID(uuidString: String(arguments[1].dropFirst(prefix.count))) != nil,
              arguments[2].hasPrefix("/") else { throw NSError(domain: "WinMuxBrowser.TestService", code: 1) }
        service = arguments[1]
        testReport = URL(fileURLWithPath: arguments[2])
        sidebarEnabled = arguments.count >= 4
        if nativeMode {
            guard arguments[4].hasPrefix("/") else { throw NSError(domain: "WinMuxBrowser.NativeState", code: 1) }
            nativeState = URL(fileURLWithPath: arguments[4])
            if arguments.count == 7 {
                guard arguments[5] == "--native-process", let pid = Int32(arguments[6]), pid > 0 else {
                    throw NSError(domain: "WinMuxBrowser.NativeProcess", code: 1)
                }
                nativeProcessID = pid
            }
        }
    }
#if canImport(AppBundle)
    let appDelegate = WinMuxApplicationDelegate()
    if sidebarEnabled {
        NSApplication.shared.setActivationPolicy(.accessory)
        if let nativeState {
            NSApplication.shared.delegate = appDelegate
            let scopedPID = nativeProcessID
            Task { @MainActor in
                do {
                    try await startBrowserNativeManagement(stateDirectory: nativeState, nativeProcessID: scopedPID)
                    FileHandle.standardError.write(Data("Native workspace ready (isolated state).\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("Native workspace refused: \(error.localizedDescription)\n".utf8))
                    NSApplication.shared.terminate(nil)
                }
            }
        } else {
            DispatchQueue.main.async { BrowserWorkspaceController.shared.showIsolatedSidebar() }
        }
    }
#else
    guard !sidebarEnabled else { throw NSError(domain: "WinMuxBrowser.SidebarUnavailable", code: 1) }
#endif
    let delegate = ListenerDelegate(testReport: testReport, sidebarEnabled: sidebarEnabled)
    let listener = NSXPCListener(machServiceName: service)
    listener.setConnectionCodeSigningRequirement(requirement)
    listener.delegate = delegate
    listener.resume()
    // Enrollment is transport-only; native management requires explicit activation.
    withExtendedLifetime((listener, delegate)) {
#if canImport(AppBundle)
        if sidebarEnabled { withExtendedLifetime(appDelegate) { NSApplication.shared.run() }; return }
#endif
        RunLoop.current.run()
    }
} catch {
    FileHandle.standardError.write(Data("Helper refused to start: \(error.localizedDescription)\n".utf8))
    exit(1)
}
