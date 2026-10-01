import BridgeCore
import BridgeProtocol
import Foundation
import WorkspaceCore

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

    init(connection: NSXPCConnection, testReport: URL?) {
        self.connection = connection
        self.testReport = testReport
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
            guard data.count <= 1_048_576,
                  session.accept(epoch: epoch, sequence: sequence, minimumVersion: 2),
                  let message = try? JSONDecoder().decode(BrowserInventoryMessage.self, from: data),
                  inventory.apply(message) else { return (false, inventory.revision, false) }
            if message.full { fullMessages += 1 } else { deltaMessages += 1 }
            let startTest = testReport != nil && !testStarted && inventory.tabs.count == 2
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
    init(testReport: URL?) { self.testReport = testReport }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: WMWorkspaceBridge.self)
        connection.remoteObjectInterface = NSXPCInterface(with: WMBrowserSurfaceOwner.self)
        connection.exportedObject = SessionEndpoint(connection: connection, testReport: testReport)
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
    let arguments = CommandLine.arguments
    if arguments.count > 1 {
        let prefix = SigningIdentity.serviceName + ".test."
        guard arguments.count == 3, arguments[1].hasPrefix(prefix),
              UUID(uuidString: String(arguments[1].dropFirst(prefix.count))) != nil,
              arguments[2].hasPrefix("/") else { throw NSError(domain: "WinMuxBrowser.TestService", code: 1) }
        service = arguments[1]
        testReport = URL(fileURLWithPath: arguments[2])
    }
    let delegate = ListenerDelegate(testReport: testReport)
    let listener = NSXPCListener(machServiceName: service)
    listener.setConnectionCodeSigningRequirement(requirement)
    listener.delegate = delegate
    listener.resume()
    // This M0 control-plane process intentionally does not start AX management:
    // the existing WinMux may still own native windows during qualification.
    withExtendedLifetime((listener, delegate)) { RunLoop.current.run() }
} catch {
    FileHandle.standardError.write(Data("Helper refused to start: \(error.localizedDescription)\n".utf8))
    exit(1)
}
