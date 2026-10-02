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
                BrowserWorkspaceController.shared.connected(id, processID: pid, sendLayout: { [weak self] request, completion in
                    guard let self else { completion(.unavailable); return }
                    self.sendLayout(request, completion: completion)
                }) { [weak self] request, completion in
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
        let reply: @Sendable (String) -> Void = { outcome in
            DispatchQueue.main.async { completion(BrowserActionReply(rawValue: outcome) ?? .invalidRequest) }
        }
        if (session.version ?? 0) >= 4 {
            proxy.performBrowserAction(request.action.rawValue, surface: request.surfaceID.description,
                                       url: request.url, epoch: request.epoch.uuidString,
                                       operation: request.operation.uuidString,
                                       revision: request.revision, generation: request.generation, reply: reply)
        } else if request.action == .focus || request.action == .close || request.action == .cancelFocus {
            proxy.performAction(request.action.rawValue, surface: request.surfaceID.description,
                                epoch: request.epoch.uuidString, operation: request.operation.uuidString,
                                revision: request.revision, generation: request.generation, reply: reply)
        } else {
            completion(.unsupported)
        }
    }

    @MainActor private func sendLayout(_ request: BrowserLayoutRequest,
                                      completion: @escaping @MainActor (BrowserActionReply) -> Void) {
        guard (session.version ?? 0) >= 3, !lock.withLock({ closed }), let connection,
              let data = try? JSONEncoder().encode(request.hosts), data.count <= 262144,
              let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                  DispatchQueue.main.async { completion(.unavailable) }
              }) as? WMBrowserSurfaceOwner else { completion(.unavailable); return }
        proxy.applyLayout(data, epoch: request.epoch.uuidString, operation: request.operation.uuidString,
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
                let id = connectionID, version = session.version ?? 1
                // Enqueue while holding the endpoint lock: invalidation cannot
                // overtake a validated update and resurrect disconnected rows.
                DispatchQueue.main.async { BrowserWorkspaceController.shared.received(snapshot, epoch: epochID, connection: id, protocolVersion: version) }
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if (self.session.version ?? 0) >= 3 { Task { await self.exerciseLayout(epoch: epoch) } }
                    else { self.exerciseActions(epoch: epoch) }
                }
            }
        }
    }

    @MainActor private func testLayout(_ hosts: [BrowserHostPlacement], remote: BrowserOwnerProxy,
                                      epoch: String, revision: UInt64, generation: UInt64,
                                      operation: String = UUID().uuidString,
                                      omitNativeControls: Bool = false) async -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard var data = try? encoder.encode(hosts) else { return "invalid_fixture" }
        if omitNativeControls {
            guard var legacy = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return "invalid_fixture" }
            for index in legacy.indices { legacy[index].removeValue(forKey: "native_controls") }
            guard let encoded = try? JSONSerialization.data(withJSONObject: legacy) else { return "invalid_fixture" }
            data = encoded
        }
        return await withCheckedContinuation { continuation in
            remote.value.applyLayout(data, epoch: epoch, operation: operation, revision: revision,
                                     generation: generation) { continuation.resume(returning: $0) }
        }
    }

    @MainActor private func testAction(_ action: String, surface: SurfaceID, remote: BrowserOwnerProxy,
                                      epoch: String, url: String? = nil, revision: UInt64? = nil,
                                      operation: String = UUID().uuidString) async -> String {
        let currentRevision = revision ?? lock.withLock { inventory.revision }
        let outcome: String = await withCheckedContinuation { continuation in
            remote.value.performBrowserAction(action, surface: surface.description, url: url, epoch: epoch,
                operation: operation, revision: currentRevision, generation: 0) {
                    continuation.resume(returning: $0)
                }
        }
        // Let the helper consume a just-published page-state update. Explicit
        // revisions (including the stale-revision test) are never retried.
        if outcome == "stale_revision", revision == nil,
           let newer = await waitForTestInventory({ $0.revision > currentRevision }) {
            return await testAction(action, surface: surface, remote: remote, epoch: epoch,
                                    url: url, revision: newer.revision, operation: operation)
        }
        return outcome
    }

    /// Bounded waits use authoritative inventory, not a fixed navigation delay.
    /// This is called only by the temporary-service synthetic browser fixture.
    @MainActor private func waitForTestInventory(_ predicate: (BrowserInventory) -> Bool) async -> BrowserInventory? {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        repeat {
            let snapshot = lock.withLock { closed ? nil : inventory }
            guard let snapshot else { return nil }
            if predicate(snapshot) { return snapshot }
            try? await Task.sleep(for: .milliseconds(25))
        } while DispatchTime.now().uptimeNanoseconds < deadline
        return nil
    }

    @MainActor private func exerciseLayout(epoch: String) async {
        guard let value = connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? WMBrowserSurfaceOwner else { return }
        let remote = BrowserOwnerProxy(value)
        let snapshot = lock.withLock { inventory }
        let ids = snapshot.tabs.keys.sorted { $0.description < $1.description }
        guard ids.count == 2 else { return }
        let first = UUID(), second = UUID()
        let frame = SurfaceFrame(x: 100, y: 100, width: 600, height: 600)
        let secondFrame = SurfaceFrame(x: 700, y: 100, width: 600, height: 600)
        let split = [BrowserHostPlacement(containerID: first, surfaces: [ids[0]], selected: ids[0], frame: frame, visible: true, nativeControls: true),
                     BrowserHostPlacement(containerID: second, surfaces: [ids[1]], selected: ids[1], frame: secondFrame, visible: true, nativeControls: true)]
        let operation = UUID().uuidString
        noteTest("layout_split", await testLayout(split, remote: remote, epoch: epoch,
            revision: snapshot.revision, generation: 1, operation: operation))
        noteTest("layout_repeat", await testLayout(split, remote: remote, epoch: epoch,
            revision: snapshot.revision, generation: 1, operation: operation))
        noteTest("layout_stale", await testLayout(split, remote: remote, epoch: epoch,
            revision: snapshot.revision, generation: 1))
        guard let splitState = await waitForTestInventory({ state in
            state.tabs[ids[0]]?.hostFrame == frame && state.tabs[ids[1]]?.hostFrame == secondFrame &&
            state.tabs.values.allSatisfy { $0.hostManaged }
        }) else { noteTest("layout_split_state", "timed_out"); return }
        let windows = Dictionary(uniqueKeysWithValues: splitState.tabs.values.compactMap { tab in
            tab.hostWindowID.map { (tab.surfaceID, $0) }
        })
        noteTest("layout_split_host_count", String(Set(splitState.tabs.values.map(\.hostID)).count))
        noteTest("layout_independent_native_windows", windows.count == 2 && Set(windows.values).count == 2 &&
            windows.values.allSatisfy { $0 > 0 } ? "yes" : "no")
        noteTest("layout_identity_retained", Set(splitState.tabs.keys) == Set(ids) ? "yes" : "no")
        noteTest("layout_frames_match", "yes")
        noteTest("layout_managed", "yes")

        // A Winmux stack shares placement, never Chromium's host/tabstrip.
        let grouped = [BrowserHostPlacement(containerID: first, surfaces: ids, selected: ids[0], frame: frame, visible: true, nativeControls: true)]
        noteTest("layout_conflict", await testLayout(grouped, remote: remote, epoch: epoch,
            revision: snapshot.revision, generation: 1, operation: operation))
        noteTest("layout_group", await testLayout(grouped, remote: remote, epoch: epoch,
            revision: splitState.revision, generation: 2))
        guard let groupedState = await waitForTestInventory({ state in
            state.tabs[ids[0]]?.hostVisible == true && state.tabs[ids[1]]?.hostVisible == false &&
            state.tabs.values.allSatisfy { $0.hostFrame == frame }
        }) else { noteTest("layout_group_state", "timed_out"); return }
        noteTest("layout_grouped_host_count", String(Set(groupedState.tabs.values.map(\.hostID)).count))
        noteTest("layout_grouped_window_ids_retained", ids.allSatisfy {
            groupedState.tabs[$0]?.hostWindowID == windows[$0]
        } ? "yes" : "no")
        noteTest("layout_selected_page_only", groupedState.tabs.values.filter { $0.hostVisible == true }.count == 1 ? "yes" : "no")

        let hidden = [BrowserHostPlacement(containerID: first, surfaces: ids, selected: nil, frame: frame, visible: false, nativeControls: true)]
        noteTest("layout_hide", await testLayout(hidden, remote: remote, epoch: epoch,
            revision: groupedState.revision, generation: 3))
        guard let hiddenState = await waitForTestInventory({ $0.tabs.values.allSatisfy { $0.hostVisible == false } }) else {
            noteTest("layout_hidden", "timed_out"); return
        }
        noteTest("layout_hidden", "yes")
        guard let minimum = hiddenState.tabs[ids[0]]?.hostMinimumSize, minimum.width > 1 else {
            noteTest("layout_minimum_rejected", "missing_owner_minimum"); return
        }
        let tooSmall = [BrowserHostPlacement(containerID: first, surfaces: ids, selected: ids[0],
            frame: .init(x: 100, y: 100, width: minimum.width - 1, height: 600), visible: true, nativeControls: true)]
        noteTest("layout_minimum_rejected", await testLayout(tooSmall, remote: remote, epoch: epoch,
            revision: hiddenState.revision, generation: 4))
        noteTest("layout_minimum_no_mutation", lock.withLock { inventory.tabs == hiddenState.tabs } ? "yes" : "no")
        // A protocol-3 helper never supplied native_controls. Its layout must
        // restore Chromium controls even when it inherits previously managed hosts.
        noteTest("layout_legacy_controls", await testLayout(split, remote: remote, epoch: epoch,
            revision: hiddenState.revision, generation: 5, omitNativeControls: true))
        guard let legacyState = await waitForTestInventory({ $0.tabs.count == 2 && $0.tabs.values.allSatisfy { !$0.hostManaged } }) else {
            noteTest("layout_legacy_controls_restored", "timed_out"); return
        }
        noteTest("layout_legacy_controls_restored", "yes")
        noteTest("layout_readopt", await testLayout(split, remote: remote, epoch: epoch,
            revision: legacyState.revision, generation: 6))
        guard let readopted = await waitForTestInventory({ $0.tabs.count == 2 && $0.tabs.values.allSatisfy { $0.hostManaged } }) else {
            noteTest("layout_readopted_window_ids", "timed_out"); return
        }
        noteTest("layout_readopted_window_ids", ids.allSatisfy { readopted.tabs[$0]?.hostWindowID == windows[$0] } ? "yes" : "no")
        if (session.version ?? 0) >= 4 {
            guard await exerciseNavigation(epoch: epoch, remote: remote, ids: ids, windows: windows) else { return }
        }
        exerciseActions(epoch: epoch)
    }

    @MainActor private func exerciseNavigation(epoch: String, remote: BrowserOwnerProxy,
                                              ids: [SurfaceID], windows: [SurfaceID: UInt32]) async -> Bool {
        let id = ids[0], firstURL = "about:blank#winmux-navigation-a", secondURL = "about:blank#winmux-navigation-b"
        let legacy = await withCheckedContinuation { continuation in
            remote.value.performAction("reload", surface: id.description, epoch: epoch,
                operation: UUID().uuidString, revision: 0, generation: 0) {
                    continuation.resume(returning: $0)
                }
        }
        noteTest("navigation_legacy_rejected", legacy)
        noteTest("navigate_first", await testAction("navigate", surface: id, remote: remote, epoch: epoch, url: firstURL))
        guard await waitForTestInventory({ $0.tabs[id]?.url == firstURL && $0.tabs[id]?.isLoading == false }) != nil else {
            noteTest("navigate_first_state", "timed_out"); return false
        }
        let operation = UUID().uuidString, revision = lock.withLock { inventory.revision }
        noteTest("navigate_second", await testAction("navigate", surface: id, remote: remote, epoch: epoch,
            url: secondURL, revision: revision, operation: operation))
        noteTest("navigate_repeat", await testAction("navigate", surface: id, remote: remote, epoch: epoch,
            url: secondURL, revision: revision, operation: operation))
        noteTest("navigate_payload_conflict", await testAction("navigate", surface: id, remote: remote, epoch: epoch,
            url: firstURL, revision: revision, operation: operation))
        guard await waitForTestInventory({ $0.tabs[id]?.url == secondURL && $0.tabs[id]?.canGoBack == true &&
            $0.tabs[id]?.isLoading == false }) != nil else { noteTest("navigate_history_state", "timed_out"); return false }
        noteTest("navigate_stale_revision", await testAction("reload", surface: id, remote: remote, epoch: epoch, revision: 0))
        noteTest("navigate_invalid_url", await testAction("navigate", surface: id, remote: remote, epoch: epoch,
            url: "javascript:void(0)"))
        noteTest("back", await testAction("back", surface: id, remote: remote, epoch: epoch))
        guard await waitForTestInventory({ $0.tabs[id]?.url == firstURL && $0.tabs[id]?.canGoForward == true }) != nil else {
            noteTest("back_state", "timed_out"); return false
        }
        noteTest("back_state", "yes")
        noteTest("forward", await testAction("forward", surface: id, remote: remote, epoch: epoch))
        guard await waitForTestInventory({ $0.tabs[id]?.url == secondURL && $0.tabs[id]?.isLoading == false }) != nil else {
            noteTest("forward_state", "timed_out"); return false
        }
        noteTest("forward_state", "yes")
        noteTest("reload", await testAction("reload", surface: id, remote: remote, epoch: epoch))
        // about:blank may finish synchronously; stop is still a valid dispatch.
        _ = await waitForTestInventory { $0.tabs[id]?.isLoading == false }
        noteTest("stop", await testAction("stop", surface: id, remote: remote, epoch: epoch))
        noteTest("navigation_keeps_native_windows", lock.withLock { ids.allSatisfy {
            inventory.tabs[$0]?.hostWindowID == windows[$0]
        }} ? "yes" : "no")

        let newURL = "about:blank#winmux-new-window"
        noteTest("new_tab", await testAction("new_tab", surface: id, remote: remote, epoch: epoch, url: newURL))
        guard let newState = await waitForTestInventory({ state in
            state.tabs.count == 3 && Set(state.tabs.values.map(\.hostID)).count == 3 &&
            state.tabs.values.contains { $0.url == newURL && !$0.isLoading }
        }), let newPage = newState.tabs.values.first(where: { $0.url == newURL }) else {
            noteTest("new_tab_state", "timed_out"); return false
        }
        let windowIDs = newState.tabs.values.compactMap(\.hostWindowID)
        noteTest("new_tab_independent_native_window", windowIDs.count == 3 && Set(windowIDs).count == 3 &&
            ids.allSatisfy { newState.tabs[$0]?.hostWindowID == windows[$0] } ? "yes" : "no")
        noteTest("new_tab_close", await testAction("close", surface: newPage.surfaceID, remote: remote, epoch: epoch))
        guard await waitForTestInventory({ Set($0.tabs.keys) == Set(ids) }) != nil else {
            noteTest("new_tab_cleanup", "timed_out"); return false
        }
        return true
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
        guard lock.withLock({
            if closed { return false }
            testOutcomes[action] = outcome
            return true
        }) else { return }
        writeTestReport()
    }

    private func writeTestReport() {
        guard let testReport else { return }
        lock.withLock {
            guard !closed else { return }
            // Counts and outcomes only: no titles, URLs, profile paths or vault data.
            let report: [String: Any] = ["scope": "isolated_authenticated_inventory_actions", "revision": inventory.revision,
                                       "tab_count": inventory.tabs.count, "outcomes": testOutcomes,
                                       "full_messages": fullMessages, "delta_messages": deltaMessages,
                                       "hosts": inventory.tabs.values.map { tab in
                                           ["host_id": tab.hostID, "native_window_id": tab.hostWindowID.map { $0 as Any } ?? NSNull(),
                                            "managed": tab.hostManaged, "visible": tab.hostVisible.map { $0 as Any } ?? NSNull(),
                                            "minimum_size": tab.hostMinimumSize.map { ["width": $0.width, "height": $0.height] as Any } ?? NSNull(),
                                            "frame": tab.hostFrame.map { ["x": $0.x, "y": $0.y, "width": $0.width, "height": $0.height] as Any } ?? NSNull()]
                                       }]
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
#if canImport(AppBundle)
    if CommandLine.arguments.dropFirst().first == "--workspace-setup" {
        let args = CommandLine.arguments
        guard args.count == 2 || (args.count == 4 && args[2] == "--fixture-process" && Int32(args[3]) != nil) else {
            throw WorkspaceActivationError.invalidRequest
        }
        let setup = try WorkspaceSetup(fixturePID: args.count == 4 ? Int32(args[3]) : nil)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.delegate = setup
        withExtendedLifetime(setup) { NSApplication.shared.run() }
        exit(0)
    }
#endif
    let team = try SigningIdentity.ownTeamID()
    guard let requirement = SigningIdentity.requirement(identifier: SigningIdentity.browserID, teamID: team) else {
        throw NSError(domain: "WinMuxBrowser.Signing", code: 2)
    }
    var service = SigningIdentity.serviceName
    var testReport: URL?
    var sidebarEnabled = false
    var nativeState: URL?
    var nativeProcessID: Int32?
    var activation: WorkspaceActivation?
    let arguments = CommandLine.arguments
    if arguments.count >= 2 && arguments[1] == "--managed-workspace" {
#if canImport(AppBundle)
        let store = try WorkspaceActivationStore()
        let validationService = Bundle.main.object(forInfoDictionaryKey: "WinMuxValidationService") as? String
        guard (arguments.count == 2 || (arguments.count == 3 && arguments[2] == validationService)),
              let request = try store.readRequest(), request.browserPath == (try containingBrowser()).path,
              request.machService == (arguments.count == 3 ? arguments[2] : WorkspaceActivation.serviceName) else {
            throw WorkspaceActivationError.differentPackage
        }
        try store.prepareDirectories(for: request)
        activation = request
        nativeState = request.nativeState(in: store.root)
        nativeProcessID = request.nativeProcessID
        service = request.machService
        sidebarEnabled = true
#else
        throw WorkspaceActivationError.unavailable
#endif
    } else if arguments.count > 1 {
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
            let request = activation
            Task { @MainActor in
                do {
                    try await startBrowserNativeManagement(stateDirectory: nativeState, nativeProcessID: scopedPID,
                        expectedProcessLaunch: request?.nativeProcessLaunch, workspaceShortcuts: request != nil)
                    if let request {
                        try WorkspaceActivationStore().writeStatus(.init(requestID: request.id, phase: "ready",
                            helperPID: getpid(), helperLaunch: processLaunchDate(getpid())))
                    }
                    FileHandle.standardError.write(Data("Native workspace ready (isolated state).\n".utf8))
                } catch {
                    if let request {
                        try? WorkspaceActivationStore().writeStatus(.init(requestID: request.id, phase: "failed",
                            helperPID: getpid(), helperLaunch: processLaunchDate(getpid()), detail: error.localizedDescription))
                    }
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
