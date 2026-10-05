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
    private let windowControlsEnabled: Bool
    private var closed = false
    private let authenticatedBrowser: (@Sendable (Int32) -> Void)?

    init(connection: NSXPCConnection, testReport: URL?, sidebarEnabled: Bool, windowControlsEnabled: Bool,
         authenticatedBrowser: (@Sendable (Int32) -> Void)? = nil) {
        self.connection = connection
        self.testReport = testReport
        self.sidebarEnabled = sidebarEnabled
        self.windowControlsEnabled = windowControlsEnabled
        self.authenticatedBrowser = authenticatedBrowser
        super.init()
#if canImport(AppBundle)
        if sidebarEnabled {
            let id = connectionID, pid = connection.processIdentifier
            DispatchQueue.main.async { [self] in
                BrowserWorkspaceController.shared.connected(id, processID: pid, sendLayout: { [weak self] request, completion in
                    guard let self else { completion(.unavailable); return }
                    self.sendLayout(request, completion: completion)
                }, sendNewTab: { [weak self] request, completion in
                    guard let self else { completion(.unavailable, nil); return }
                    self.sendNewTab(request, completion: completion)
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

    @MainActor private func sendNewTab(_ request: BrowserNewTabRequest,
                                      completion: @escaping @MainActor (BrowserActionReply, SurfaceID?) -> Void) {
        guard (session.version ?? 0) >= 5, !lock.withLock({ closed }), let connection,
              let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                  DispatchQueue.main.async { completion(.unavailable, nil) }
              }) as? WMBrowserSurfaceOwner else { completion(.unavailable, nil); return }
        let reply: @Sendable (String, String?) -> Void = { outcome, surface in
            DispatchQueue.main.async {
                completion(BrowserActionReply(rawValue: outcome) ?? .invalidRequest, surface.flatMap(SurfaceID.init(string:)))
            }
        }
        if let profile = request.workspaceProfile {
            guard (session.version ?? 0) >= 6 else { completion(.unsupported, nil); return }
            proxy.openBrowserTab(inWorkspaceProfile: profile.key, name: profile.name, url: request.url,
                                 epoch: request.epoch.uuidString, operation: request.operation.uuidString,
                                 revision: request.revision, reply: reply)
        } else {
            proxy.openBrowserTab(request.sourceSurfaceID?.description, profile: request.profileID?.uuidString,
                                 url: request.url, epoch: request.epoch.uuidString,
                                 operation: request.operation.uuidString, revision: request.revision, reply: reply)
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
        if epoch != nil, let connection { authenticatedBrowser?(connection.processIdentifier) }
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
                                      operation: String = UUID().uuidString, generation: UInt64 = 0) async -> String {
        let currentRevision = revision ?? lock.withLock { inventory.revision }
        let outcome: String = await withCheckedContinuation { continuation in
            remote.value.performBrowserAction(action, surface: surface.description, url: url, epoch: epoch,
                operation: operation, revision: currentRevision, generation: generation) {
                    continuation.resume(returning: $0)
                }
        }
        // Let the helper consume a just-published page-state update. Explicit
        // revisions (including the stale-revision test) are never retried.
        // This fixture stops an about:blank reload after it finishes. Do not
        // spend its one retry on the intermediate loading-start inventory.
        if outcome == "stale_revision", revision == nil,
           let newer = await waitForTestInventory({ state in
               state.revision > currentRevision &&
                   (action != "stop" || state.tabs[surface]?.isLoading == false)
           }) {
            return await testAction(action, surface: surface, remote: remote, epoch: epoch,
                                    url: url, revision: newer.revision, operation: operation, generation: generation)
        }
        return outcome
    }

    /// Bounded waits use authoritative inventory, not a fixed navigation delay.
    /// This is called only by the temporary-service synthetic browser fixture.
    @MainActor private func waitForTestInventory(_ predicate: (BrowserInventory) -> Bool, timeoutMilliseconds: UInt64 = 2000) async -> BrowserInventory? {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutMilliseconds * 1_000_000
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
            if windowControlsEnabled {
                guard await exerciseNativeWindowControls(epoch: epoch, remote: remote, ids: ids, windows: windows,
                    split: split, peerContainer: second) else { return }
            }
            guard await exerciseRepeatedGroupSwitches(epoch: epoch, remote: remote, ids: ids,
                windows: windows, split: split) else { return }
            guard await exerciseNavigation(epoch: epoch, remote: remote, ids: ids, windows: windows) else { return }
        }
        exerciseActions(epoch: epoch)
    }

    @MainActor private func exerciseRepeatedGroupSwitches(epoch: String, remote: BrowserOwnerProxy,
                                                         ids: [SurfaceID], windows: [SurfaceID: UInt32],
                                                         split: [BrowserHostPlacement]) async -> Bool {
        // Exercise the warm path after adoption and native presentation changes.
        // Every switch must retain each host and its exact original tile frame.
        var completed = 0
        var generation: UInt64 = 99
        func apply(_ placements: [BrowserHostPlacement]) async -> String {
            for attempt in 0..<3 {
                let revision = lock.withLock { inventory.revision }
                generation += 1
                let outcome = await testLayout(placements, remote: remote, epoch: epoch,
                    revision: revision, generation: generation)
                if outcome != "stale_revision" { return outcome }
                // Native fullscreen/zoom notifications can still be settling.
                // Match the normal adapter's revision recovery, never retry a
                // different failure or resend with an already consumed generation.
                FileHandle.standardError.write(Data("Repeated-group fixture stale revision \(revision), attempt \(attempt + 1).\n".utf8))
                if attempt == 2 { return "stale_revision_exhausted" }
                guard await waitForTestInventory({ $0.revision > revision }) != nil else {
                    return "stale_revision_without_new_inventory"
                }
            }
            return "invalid_fixture"
        }
        for index in 0..<20 {
            let selected = ids[index % ids.count]
            let placements = split.map { placement in
                BrowserHostPlacement(containerID: placement.containerID, surfaces: placement.surfaces,
                    selected: placement.selected,
                    frame: .init(x: placement.x, y: placement.y, width: placement.width, height: placement.height),
                    visible: placement.surfaces.contains(selected), nativeControls: true)
            }
            let outcome = await apply(placements)
            guard outcome == "issued" else {
                noteTest("layout_repeated_group_failure", outcome)
                noteTest("layout_repeated_group_switches", String(completed))
                return false
            }
            guard await waitForTestInventory({ state in
                      Set(state.tabs.keys) == Set(ids) && split.allSatisfy { placement in
                          let id = placement.surfaces[0]
                          guard let tab = state.tabs[id] else { return false }
                          return tab.hostWindowID == windows[id] && tab.hostManaged &&
                              tab.hostVisible == (id == selected) &&
                              tab.hostFrame == SurfaceFrame(x: placement.x, y: placement.y,
                                  width: placement.width, height: placement.height)
                      }
                  }) != nil else {
                noteTest("layout_repeated_group_failure", "inventory_or_frame_mismatch")
                noteTest("layout_repeated_group_switches", String(completed))
                return false
            }
            completed += 1
        }
        noteTest("layout_repeated_group_switches", String(completed))
        let outcome = await apply(split)
        guard outcome == "issued", await waitForTestInventory({ state in
            Set(state.tabs.keys) == Set(ids) && split.allSatisfy { placement in
                let id = placement.surfaces[0]
                guard let tab = state.tabs[id] else { return false }
                return tab.hostWindowID == windows[id] && tab.hostManaged && tab.hostVisible == true &&
                    tab.hostFrame == SurfaceFrame(x: placement.x, y: placement.y,
                        width: placement.width, height: placement.height)
            }
        }) != nil else {
            noteTest("layout_repeated_group_failure", outcome == "issued" ? "restore_inventory_or_frame_mismatch" : outcome)
            noteTest("layout_repeated_group_restore", "failed")
            return false
        }
        noteTest("layout_repeated_group_restore", "yes")
        return true
    }

    @MainActor private func exerciseNativeWindowControls(epoch: String, remote: BrowserOwnerProxy,
                                                        ids: [SurfaceID], windows: [SurfaceID: UInt32],
                                                        split: [BrowserHostPlacement], peerContainer: UUID) async -> Bool {
        let id = ids[0], peer = ids[1]
        let peerFrame = SurfaceFrame(x: 300, y: 150, width: 700, height: 600)
        let peerOnly = [BrowserHostPlacement(containerID: peerContainer, surfaces: [peer], selected: peer,
            frame: peerFrame, visible: true, nativeControls: true)]
        noteTest("native_minimize", await testAction("minimize", surface: id, remote: remote, epoch: epoch))
        guard let minimized = await waitForTestInventory({ $0.tabs[id]?.hostMinimized == true }) else {
            noteTest("native_minimize_state", "timed_out"); return false
        }
        noteTest("native_minimize_state", "yes")
        noteTest("native_minimize_peer_layout", await testLayout(peerOnly, remote: remote, epoch: epoch,
            revision: minimized.revision, generation: 7))
        guard let duringMinimize = await waitForTestInventory({ state in
            state.tabs[id]?.hostMinimized == true && state.tabs[peer]?.hostFrame == peerFrame &&
                state.tabs.values.allSatisfy { $0.hostManaged }
        }) else { noteTest("native_minimize_survives_layout", "timed_out"); return false }
        noteTest("native_minimize_survives_layout", "yes")
        noteTest("native_minimize_keeps_window_ids", ids.allSatisfy {
            duringMinimize.tabs[$0]?.hostWindowID == windows[$0]
        } ? "yes" : "no")
        // This is the same authenticated focus action dispatched by sidebar
        // selection, and must explicitly restore the real native Dock window.
        noteTest("native_restore_focus", await testAction("focus", surface: id, remote: remote,
            epoch: epoch, generation: 1))
        guard let restored = await waitForTestInventory({
            $0.tabs[id]?.hostMinimized == false && $0.tabs[id]?.focused == true
        }) else { noteTest("native_restore_state", "timed_out"); return false }
        noteTest("native_restore_state", "yes")
        noteTest("native_restore_layout", await testLayout(split, remote: remote, epoch: epoch,
            revision: restored.revision, generation: 8))
        guard await waitForTestInventory({ state in
            split.allSatisfy { state.tabs[$0.surfaces[0]]?.hostFrame == SurfaceFrame(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        }) != nil else { noteTest("native_restore_frames", "timed_out"); return false }
        noteTest("native_restore_frames", "yes")

        noteTest("native_fullscreen_enter", await testAction("fullscreen", surface: id, remote: remote, epoch: epoch))
        guard let fullscreen = await waitForTestInventory({ $0.tabs[id]?.hostFullscreen == true }, timeoutMilliseconds: 5000) else {
            noteTest("native_fullscreen_state", "timed_out"); return false
        }
        noteTest("native_fullscreen_state", "yes")
        noteTest("native_fullscreen_peer_layout", await testLayout(peerOnly, remote: remote, epoch: epoch,
            revision: fullscreen.revision, generation: 9))
        guard let duringFullscreen = await waitForTestInventory({ state in
            state.tabs[id]?.hostFullscreen == true && state.tabs[peer]?.hostFrame == peerFrame &&
                state.tabs.values.allSatisfy { $0.hostManaged }
        }) else { noteTest("native_fullscreen_survives_layout", "timed_out"); return false }
        noteTest("native_fullscreen_survives_layout", "yes")
        noteTest("native_fullscreen_keeps_window_ids", ids.allSatisfy {
            duringFullscreen.tabs[$0]?.hostWindowID == windows[$0]
        } ? "yes" : "no")
        noteTest("native_fullscreen_exit", await testAction("fullscreen", surface: id, remote: remote, epoch: epoch))
        guard let normal = await waitForTestInventory({ state in
            state.tabs[id]?.hostFullscreen == false && state.tabs.values.allSatisfy { $0.hostManaged }
        }, timeoutMilliseconds: 5000) else { noteTest("native_fullscreen_exit_state", "timed_out"); return false }
        noteTest("native_fullscreen_exit_state", "yes")
        noteTest("native_fullscreen_return_layout", await testLayout(split, remote: remote, epoch: epoch,
            revision: normal.revision, generation: 10))
        guard let tiled = await waitForTestInventory({ state in
            split.allSatisfy { state.tabs[$0.surfaces[0]]?.hostFrame == SurfaceFrame(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } &&
                state.tabs.values.allSatisfy { $0.hostManaged && !$0.hostMinimized && !$0.hostFullscreen }
        }) else { noteTest("native_fullscreen_returns_to_tiles", "timed_out"); return false }
        noteTest("native_fullscreen_returns_to_tiles", "yes")
        noteTest("native_window_actions_keep_surfaces", Set(tiled.tabs.keys) == Set(ids) && ids.allSatisfy {
            tiled.tabs[$0]?.hostWindowID == windows[$0]
        } ? "yes" : "no")
        noteTest("native_zoom_enter", await testAction("zoom", surface: id, remote: remote, epoch: epoch))
        guard let zoomed = await waitForTestInventory({ $0.tabs[id]?.hostZoomed == true }) else {
            noteTest("native_zoom_state", "timed_out"); return false
        }
        noteTest("native_zoom_state", "yes")
        noteTest("native_zoom_peer_layout", await testLayout(peerOnly, remote: remote, epoch: epoch,
            revision: zoomed.revision, generation: 11))
        guard let duringZoom = await waitForTestInventory({ state in
            state.tabs[id]?.hostZoomed == true && state.tabs[peer]?.hostFrame == peerFrame &&
                state.tabs.values.allSatisfy { $0.hostManaged }
        }) else { noteTest("native_zoom_survives_layout", "timed_out"); return false }
        noteTest("native_zoom_survives_layout", "yes")
        noteTest("native_zoom_keeps_window_ids", ids.allSatisfy {
            duringZoom.tabs[$0]?.hostWindowID == windows[$0]
        } ? "yes" : "no")
        noteTest("native_zoom_exit", await testAction("zoom", surface: id, remote: remote, epoch: epoch))
        guard let unzoomed = await waitForTestInventory({ state in
            state.tabs[id]?.hostZoomed == false && state.tabs.values.allSatisfy { $0.hostManaged }
        }) else { noteTest("native_zoom_exit_state", "timed_out"); return false }
        noteTest("native_zoom_exit_state", "yes")
        noteTest("native_zoom_return_layout", await testLayout(split, remote: remote, epoch: epoch,
            revision: unzoomed.revision, generation: 12))
        guard await waitForTestInventory({ state in
            split.allSatisfy { state.tabs[$0.surfaces[0]]?.hostFrame == SurfaceFrame(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } &&
                state.tabs.values.allSatisfy { $0.hostManaged && !$0.hostMinimized && !$0.hostFullscreen && !$0.hostZoomed }
        }) != nil else { noteTest("native_zoom_returns_to_tiles", "timed_out"); return false }
        noteTest("native_zoom_returns_to_tiles", "yes")
        return true
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

    @MainActor private func testCreate(remote: BrowserOwnerProxy, epoch: String, profile: UUID? = nil,
                                      url: String? = nil, operation: String = UUID().uuidString,
                                      revision: UInt64? = nil) async -> (String, SurfaceID?) {
        let current = revision ?? lock.withLock { inventory.revision }
        return await withCheckedContinuation { continuation in
            remote.value.openBrowserTab(nil, profile: profile?.uuidString, url: url, epoch: epoch,
                                        operation: operation, revision: current) { outcome, surface in
                continuation.resume(returning: (outcome, surface.flatMap(SurfaceID.init(string:))))
            }
        }
    }

    @MainActor private func exerciseEmptyInventoryCreation(epoch: String, remote: BrowserOwnerProxy) async {
        guard let remaining = await waitForTestInventory({ $0.tabs.count == 1 }), let id = remaining.tabs.keys.first,
              case .browserTab(let profile, _) = id else { noteTest("create_empty_inventory", "timed_out"); return }
        noteTest("create_close_last", await testAction("close", surface: id, remote: remote, epoch: epoch))
        guard let empty = await waitForTestInventory({ $0.tabs.isEmpty }) else {
            noteTest("create_empty_inventory", "timed_out"); return
        }
        noteTest("create_empty_inventory", "yes")
        noteTest("create_foreign_epoch", (await testCreate(remote: remote, epoch: UUID().uuidString)).0)
        noteTest("create_stale_revision", (await testCreate(remote: remote, epoch: epoch, revision: 0)).0)
        noteTest("create_invalid_url", (await testCreate(remote: remote, epoch: epoch, url: "javascript:alert(1)")).0)
        noteTest("create_unknown_profile", (await testCreate(remote: remote, epoch: epoch, profile: UUID())).0)
        let operation = UUID().uuidString, url = "about:blank#winmux-empty-inventory"
        let (outcome, created) = await testCreate(remote: remote, epoch: epoch, profile: profile, url: url,
                                                operation: operation, revision: empty.revision)
        noteTest("create_from_empty", outcome)
        guard let created, let opened = await waitForTestInventory({ $0.tabs.count == 1 && $0.tabs[created]?.url == url }) else {
            noteTest("create_exact_identity", "timed_out"); return
        }
        noteTest("create_exact_identity", opened.tabs[created]?.hostWindowID != nil ? "yes" : "no")
        let repeated = await testCreate(remote: remote, epoch: epoch, profile: profile, url: url,
                                       operation: operation, revision: empty.revision)
        noteTest("create_repeat", repeated.0)
        noteTest("create_repeat_same_identity", repeated.1 == created ? "yes" : "no")
        noteTest("create_operation_conflict", (await testCreate(remote: remote, epoch: epoch, profile: profile,
            url: "about:blank#different", operation: operation, revision: empty.revision)).0)
        noteTest("create_cross_action_conflict", await testAction("close", surface: created, remote: remote, epoch: epoch,
            revision: empty.revision, operation: operation))
        noteTest("create_repeat_no_duplicate", lock.withLock { inventory.tabs.count == 1 } ? "yes" : "no")
        noteTest("create_close_created", await testAction("close", surface: created, remote: remote, epoch: epoch))
        guard await waitForTestInventory({ $0.tabs.isEmpty }) != nil else { noteTest("create_global_from_empty", "timed_out"); return }
        var previous = created
        for iteration in 0..<3 {
            let reopened = await testCreate(remote: remote, epoch: epoch,
                                            url: "about:blank#winmux-repeated-global-\(iteration)")
            guard reopened.0 == "issued", let next = reopened.1, next != previous,
                  await waitForTestInventory({ $0.tabs.count == 1 && $0.tabs[next] != nil }) != nil else {
                noteTest("create_global_repeated_reopen", "failed"); return
            }
            guard await testAction("close", surface: next, remote: remote, epoch: epoch) == "issued",
                  await waitForTestInventory({ $0.tabs.isEmpty }) != nil else {
                noteTest("create_global_repeated_reopen", "close_failed"); return
            }
            previous = next
        }
        noteTest("create_global_repeated_reopen", "yes")
        let global = await testCreate(remote: remote, epoch: epoch)
        noteTest("create_global_from_empty", global.0)
        if let globalID = global.1, await waitForTestInventory({ $0.tabs.count == 1 && $0.tabs[globalID] != nil }) != nil {
            noteTest("create_global_exact_identity", "yes")
            if (session.version ?? 0) >= 6 { await exerciseWorkspaceProfiles(epoch: epoch, remote: remote, shared: globalID) }
        } else { noteTest("create_global_exact_identity", "timed_out") }
    }

    @MainActor private func exerciseWorkspaceProfiles(epoch: String, remote: BrowserOwnerProxy, shared: SurfaceID) async {
        // Fresh test roots only; stable fixture IDs let a second run verify data
        // and identity survive browser restart without ever reading real profiles.
        let work = UUID(uuidString: "502aa58c-4c74-422e-9b41-e0a2fbbfc001")!
        let personal = UUID(uuidString: "502aa58c-4c74-422e-9b41-e0a2fbbfc002")!
        let base = ProcessInfo.processInfo.environment["WINMUX_TEST_PROFILE_URL"] ?? "about:blank#"
        func create(_ key: String, name: String, suffix: String, operation: String = UUID().uuidString,
                    revision: UInt64? = nil) async -> (String, SurfaceID?) {
            let current = revision ?? lock.withLock { inventory.revision }
            return await withCheckedContinuation { continuation in
                remote.value.openBrowserTab(inWorkspaceProfile: key, name: name, url: base + suffix, epoch: epoch,
                                            operation: operation, revision: current) { outcome, surface in
                    continuation.resume(returning: (outcome, surface.flatMap(SurfaceID.init(string:))))
                }
            }
        }
        noteTest("profiles_invalid_key", (await create("../escape", name: "Invalid", suffix: "invalid")).0)
        for (index, key, name, suffix) in [(0, work.uuidString, "Work", "work"),
                                          (1, personal.uuidString, "Personal", "personal"),
                                          (2, work.uuidString, "Work", "work-return"),
                                          (3, "shared", "Shared", "shared")] {
            let operation = UUID().uuidString, revision = lock.withLock { inventory.revision }
            let result = await create(key, name: name, suffix: suffix, operation: operation, revision: revision)
            guard result.0 == "issued", let id = result.1,
                  case .browserTab(let profile, _) = id,
                  let state = await waitForTestInventory({ $0.tabs[id]?.url == base + suffix && $0.tabs[id]?.isLoading == false }) else {
                noteTest("profiles_open_\(index)", result.0); return
            }
            let expected: UUID
            if index == 3, case .browserTab(let original, _) = shared { expected = original }
            else { expected = index == 1 ? personal : work }
            noteTest("profiles_open_\(index)", profile == expected && state.tabs.count == 2 &&
                state.tabs[id]?.isSharedProfile == (index == 3) ? "yes" : "wrong_account")
            if index == 0 {
                let repeated = await create(key, name: name, suffix: suffix, operation: operation, revision: revision)
                noteTest("profiles_repeat", repeated.0 == "issued" && repeated.1 == id ? "yes" : "no")
                let conflict = await create(personal.uuidString, name: "Personal", suffix: suffix, operation: operation, revision: revision)
                noteTest("profiles_conflict", conflict.0)
            }
            guard await testAction("close", surface: id, remote: remote, epoch: epoch) == "issued",
                  await waitForTestInventory({ $0.tabs.count == 1 && $0.tabs[shared] != nil }) != nil else {
                noteTest("profiles_cleanup", "failed"); return
            }
        }
        noteTest("profiles_cleanup", "yes")
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
                                            if (self.session.version ?? 0) >= 5 {
                                                Task { @MainActor in await self.exerciseEmptyInventoryCreation(epoch: epoch, remote: remote) }
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
                                            "minimized": tab.hostMinimized, "fullscreen": tab.hostFullscreen, "zoomed": tab.hostZoomed,
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
    let windowControlsEnabled: Bool
    let authenticatedBrowser: (@Sendable (Int32) -> Void)?
    init(testReport: URL?, sidebarEnabled: Bool, windowControlsEnabled: Bool,
         authenticatedBrowser: (@Sendable (Int32) -> Void)? = nil) {
        self.testReport = testReport
        self.sidebarEnabled = sidebarEnabled
        self.windowControlsEnabled = windowControlsEnabled
        self.authenticatedBrowser = authenticatedBrowser
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: WMWorkspaceBridge.self)
        connection.remoteObjectInterface = NSXPCInterface(with: WMBrowserSurfaceOwner.self)
        let endpoint = SessionEndpoint(connection: connection, testReport: testReport, sidebarEnabled: sidebarEnabled,
                                       windowControlsEnabled: windowControlsEnabled, authenticatedBrowser: authenticatedBrowser)
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
        let openWorkspace = args.count == 3 && args[2] == "--open-workspace"
        guard args.count == 2 || openWorkspace || (args.count == 4 && args[2] == "--fixture-process" && Int32(args[3]) != nil) else {
            throw WorkspaceActivationError.invalidRequest
        }
        let application = BrowserWorkspaceApplication.shared
        let setup = try WorkspaceSetup(fixturePID: args.count == 4 ? Int32(args[3]) : nil, openExistingWorkspace: openWorkspace)
        application.setActivationPolicy(.regular)
        application.delegate = setup
        withExtendedLifetime(setup) { application.run() }
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
    var windowControlsEnabled = false
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
        let windowControlsMode = arguments.count == 4 && arguments[3] == "--window-controls"
        guard (arguments.count == 3 || (arguments.count == 4 && arguments[3] == "--sidebar-preview") || nativeMode || windowControlsMode), arguments[1].hasPrefix(prefix),
              UUID(uuidString: String(arguments[1].dropFirst(prefix.count))) != nil,
              arguments[2].hasPrefix("/") else { throw NSError(domain: "WinMuxBrowser.TestService", code: 1) }
        service = arguments[1]
        testReport = URL(fileURLWithPath: arguments[2])
        sidebarEnabled = arguments.count >= 4 && !windowControlsMode
        windowControlsEnabled = windowControlsMode
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
        // Create the application subclass before any generic shared access so
        // nonactivating browser controls remain discoverable through AXWindows.
        let application = BrowserWorkspaceApplication.shared
        application.setActivationPolicy(.accessory)
        if let nativeState {
            application.delegate = appDelegate
            let scopedPID = nativeProcessID
            let request = activation
            Task { @MainActor in
                do {
                    if let request {
                        try WorkspaceActivationStore().writeStatus(.init(requestID: request.id,
                            phase: AXIsProcessTrusted() ? "starting" : "needs_accessibility",
                            helperPID: getpid(), helperLaunch: processLaunchDate(getpid())))
                    }
                    try await startBrowserNativeManagement(stateDirectory: nativeState, nativeProcessID: scopedPID,
                        expectedProcessLaunch: request?.nativeProcessLaunch, workspaceShortcuts: request != nil,
                        viewsTrial: WorkspaceActivationStore.isViewsTrial)
                    installHostedShortcutSettingsWindow()
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
    var authenticatedBrowser: (@Sendable (Int32) -> Void)?
#if canImport(AppBundle)
    if WorkspaceActivationStore.isViewsTrial, let activation, activation.validationID == nil {
        let lifetime = ManagedBrowserLifetime(request: activation, store: try WorkspaceActivationStore())
        authenticatedBrowser = { pid in
            DispatchQueue.main.async { lifetime.observeAuthenticatedBrowser(pid) }
        }
    }
#endif
    let delegate = ListenerDelegate(testReport: testReport, sidebarEnabled: sidebarEnabled,
                                    windowControlsEnabled: windowControlsEnabled, authenticatedBrowser: authenticatedBrowser)
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
#if canImport(AppBundle)
    if CommandLine.arguments.dropFirst().first == "--workspace-setup" {
        let application = BrowserWorkspaceApplication.shared
        application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "WinMux setup could not start"
        alert.informativeText = "Keep the complete WinMux app in Applications and open it again.\n\n" + error.localizedDescription
        alert.runModal()
    }
#endif
    exit(1)
}
