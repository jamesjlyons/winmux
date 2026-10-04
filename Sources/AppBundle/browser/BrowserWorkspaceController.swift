import Common
import AppKit
import SwiftUI
import WorkspaceCore

/// The authenticated helper is the only producer. No browser tab is represented
/// by a fabricated native Window or by a renderer/tab-strip index.
@MainActor
public final class BrowserWorkspaceController {
    public static let shared = BrowserWorkspaceController()
    let focusCoordinator = SurfaceFocusCoordinator()
    private let foregroundProcessID: @MainActor () -> Int32?

    init(foregroundProcessID: @escaping @MainActor () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
        self.foregroundProcessID = foregroundProcessID
    }

    var browserSidebarPins: [BrowserSidebarPin] = []
    var nativeAppSidebarPins: [NativeAppSidebarPin] = []
    var spacePinnedGroups: [SpacePinnedGroup] = []
    var pendingNativePinLaunches: [UUID: UUID] = [:]
    var failedNativePinLaunches: Set<UUID> = []
    var pendingSidebarPinOpenings: Set<UUID> = []
    var unresolvedSidebarPinOwners: [SurfaceID: UUID] = [:]
    private var sessions: [UUID: BrowserSurfaceSession] = [:]
    var pendingBrowserTabSelections: [SurfaceID: Bool] = [:]
    var pendingBrowserTabAddress: SurfaceID?
    var latestBrowserTabCreation: UUID?
    var pendingBrowserTabFocusGeneration: UInt64?
    private var processBindings: [UUID: (pid: pid_t, launch: Date?)] = [:]
    private(set) var surfaceTree = SurfaceTree()
    var usesSurfaceTree = false
    private var mixedLayoutWorkspaces: Set<String> = []
    private var placements: [SurfaceID: String] = [:]
    private var previewWindow: NSWindow?
    private let previewState = BrowserSidebarPreviewState()
    private lazy var refreshScheduler = CoalescedBrowserRefreshScheduler(isReady: { [weak self] in
        isWinMuxRuntimeReady || self?.previewWindow != nil
    }) { [weak self] in
        await self?.performScheduledRefresh()
    }
    private var browserFocusDeadline: Date?
    private var unresolvedNativeItems: Set<SurfaceID> = []
    private var closedBrowserTabs: Set<SurfaceID> = []
    private var restoredSelection: SurfaceID?
    private var recentSelections: [SurfaceID] = []
    private var restoredPlacements = false
    private var observedNativeMinimums: [SurfaceID: SurfaceMinimumSize] = [:]
    private var pendingNativeLayoutFocus: (id: SurfaceID, generation: UInt64, foregroundPID: Int32?)?

    func capturePlacementSnapshot() -> SurfaceWorkspaceSnapshot? {
        guard usesSurfaceTree else { return nil }
        syncSidebarPins()
        let selected = restoredSelection ?? focusCoordinator.target
        return .init(tree: surfaceTree, layoutWorkspaces: mixedLayoutWorkspaces.intersection(surfaceTree.roots.keys),
                     selected: selected.flatMap { surfaceTree.workspace(of: $0) == nil ? nil : $0 }, closedBrowserTabs: closedBrowserTabs,
                     browserPins: browserSidebarPins, appPins: nativeAppSidebarPins, pinnedGroups: spacePinnedGroups)
    }

    func restorePlacementSnapshot(_ snapshot: SurfaceWorkspaceSnapshot) {
        guard (try? snapshot.validated()) != nil else { return }
        pendingNativeLayoutFocus = nil
        usesSurfaceTree = true
        surfaceTree = snapshot.tree
        mixedLayoutWorkspaces = snapshot.layoutWorkspaces
        closedBrowserTabs = snapshot.closedBrowserTabs
        browserSidebarPins = snapshot.browserPins
        nativeAppSidebarPins = snapshot.appPins
        spacePinnedGroups = snapshot.pinnedGroups
        pendingNativePinLaunches = [:]
        failedNativePinLaunches = []
        restorePinnedGroups()
        pendingSidebarPinOpenings = []
        unresolvedSidebarPinOwners = [:]
        for pin in browserSidebarPins { _ = Workspace.get(byName: pin.workspaceName) }
        restoredSelection = snapshot.selected
        recentSelections = snapshot.selected.map { [$0] } ?? []
        restoredPlacements = true
        placements = [:]
        unresolvedNativeItems = []
        for (workspace, nodes) in surfaceTree.roots {
            _ = Workspace.get(byName: workspace)
            for id in nodes.flatMap(\.surfaces) {
                if case .browserTab = id { placements[id] = workspace }
                else if Window.get(bySurfaceID: id) == nil { unresolvedNativeItems.insert(id) }
            }
        }
        migrateSidebarPinsToSpaceGroups()
        // Inventory can arrive before native startup finishes reading its file.
        // Preserve such live tabs even if this snapshot predates them.
        for id in sessions.values.flatMap({ $0.inventory.tabs.keys }) where placements[id] == nil {
            placements[id] = "Recovered"
            closedBrowserTabs.remove(id)
            _ = Workspace.get(byName: "Recovered")
        }
        scheduleRefresh()
    }

    var ownsForegroundBrowser: Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        return app.bundleIdentifier == "com.jameslyons.winmux.browser.alpha" ||
            excludesNativeDiscovery(processID: app.processIdentifier)
    }

    var hasBrowserSelection: Bool {
        guard let id = focusCoordinator.target, case .browserTab = id else { return false }
        return owner(of: id) != nil
    }

    var holdsPendingBrowserFocus: Bool {
        hasBrowserSelection && browserFocusDeadline.map { $0 > .now } == true
    }

    func cancelPendingBrowserFocusHold() { browserFocusDeadline = nil }

    public func connected(_ connection: UUID, processID: Int32, sendLayout: BrowserSurfaceSession.LayoutTransport? = nil, sendNewTab: BrowserSurfaceSession.NewTabTransport? = nil, send: @escaping BrowserSurfaceSession.Transport) {
        let processLaunch = NSRunningApplication(processIdentifier: processID)?.launchDate
        for (id, oldConnection) in unresolvedSidebarPinOwners {
            guard let binding = processBindings[oldConnection] else {
                unresolvedSidebarPinOwners.removeValue(forKey: id)
                continue
            }
            if binding.pid == processID && binding.launch == processLaunch {
                unresolvedSidebarPinOwners[id] = connection
            } else {
                let originalProcess = NSRunningApplication(processIdentifier: binding.pid)
                if originalProcess?.isTerminated != false || originalProcess?.launchDate != binding.launch {
                    unresolvedSidebarPinOwners.removeValue(forKey: id)
                }
            }
        }
        processBindings = processBindings.filter { _, binding in
            binding.pid != processID && NSRunningApplication(processIdentifier: binding.pid)?.isTerminated == false
        }
        processBindings[connection] = (processID, NSRunningApplication(processIdentifier: processID)?.launchDate)
        sessions[connection] = BrowserSurfaceSession(focusCoordinator: focusCoordinator, sendLayout: sendLayout, sendNewTab: sendNewTab, send: send)
        reconcileNativeHosts()
    }

    public func received(_ message: BrowserInventoryMessage, epoch: UUID, connection: UUID, protocolVersion: Int = 2) {
        guard let session = sessions[connection] else { return }
        if session.epoch == nil { session.connect(epoch: epoch) }
        session.supportsLayout = protocolVersion >= 3
        session.supportsBrowserControls = protocolVersion >= 4
        session.supportsTabCreation = protocolVersion >= 5
        let isInitialInventory = session.inventory.revision == 0
        let oldIDs = Set(session.inventory.tabs.keys)
        guard session.reconcile(message, epoch: epoch) else { return }
        let absentPinnedIDs = reconcileSidebarPinInventory(session.inventory, full: message.full, connection: connection)
        if let target = focusCoordinator.target, session.inventory.tabs[target]?.hostMinimized == true {
            // A native titlebar or Dock action can minimize outside our toolbar.
            // Stale layout/focus replies must not reactivate that page.
            nativeSelectionChanged(nil)
        }
        for id in oldIDs.subtracting(session.inventory.tabs.keys).union(absentPinnedIDs) where owner(of: id) == nil {
            browserPinDidClose(id)
            closedBrowserTabs.insert(id)
            placements.removeValue(forKey: id)
            surfaceTree.remove(id)
        }
        // A tab restored by Chromium (including explicit undo-close) is live.
        // Stale placement never reopens it; recover it as a new placement.
        // Only the first snapshot can contain unknown pages from restoration.
        // Later full snapshots also carry newly opened pages; place those in
        // the active group just like a delta, while keeping existing placements.
        let workspace = restoredPlacements && isInitialInventory && message.full ? "Recovered" : (previewWindow == nil ? regularWorkspaceForNewItem(focus.workspace).name : "browser-alpha")
        for id in session.inventory.tabs.keys {
            closedBrowserTabs.remove(id)
            if placements[id] == nil {
                placements[id] = workspace
                if isWinMuxRuntimeReady { _ = Workspace.get(byName: workspace) }
            }
        }
        if usesSurfaceTree && !holdsPendingBrowserFocus && BrowserToolbarController.shared.focusedControlSurfaceID == nil,
           processBindings[connection]?.pid == foregroundProcessID(),
           let focused = session.inventory.tabs.values.first(where: { $0.focused && !$0.hostMinimized }),
           let workspaceName = placements[focused.surfaceID],
           let workspace = Workspace.existing(byName: workspaceName), workspace.isVisible,
           focusCoordinator.target != focused.surfaceID {
            // The browser reports native activation. Reflect clicks in the shared
            // selection without issuing a second activation back to Chromium.
            if workspace !== focus.workspace {
                _ = workspace.focusWorkspace(restoringSurfaceSelection: false)
            }
            if let generation = focusCoordinator.select(focused.surfaceID) {
                fenceBrowsers(generation: generation, target: focused.surfaceID)
            }
            surfaceTree.select(focused.surfaceID)
            rememberSelection(focused.surfaceID)
        }
        // Every browser page participates in the workspace layout immediately.
        // A first page must not wait for an explicit split/group command.
        if usesSurfaceTree && session.supportsBrowserControls {
            mixedLayoutWorkspaces.formUnion(session.inventory.tabs.keys.compactMap { placements[$0] })
        }
        completePendingBrowserTabSelections()
        scheduleRefresh()
    }

    public func disconnected(_ connection: UUID) {
        guard let session = sessions.removeValue(forKey: connection) else { return }
        for pin in browserSidebarPins {
            if let id = pin.surfaceID, session.inventory.tabs[id] != nil ||
                (pendingSidebarPinOpenings.contains(pin.id) && sessions.isEmpty) {
                unresolvedSidebarPinOwners[id] = connection
            }
        }
        if let epoch = session.epoch { session.disconnect(epoch: epoch) }
        // Retain process quarantine during reconnect. Releasing it on a transient
        // XPC loss would let AX discovery tile browser hosts as ordinary windows.
        scheduleRefresh()
    }

    func excludesNativeDiscovery(processID: pid_t) -> Bool {
        guard let process = NSRunningApplication(processIdentifier: processID), !process.isTerminated else { return false }
        return processBindings.values.contains { $0.pid == processID && $0.launch == process.launchDate }
    }

    func adoptNativeWorkspace() {
        usesSurfaceTree = BrowserNativeManagement.lease != nil
        if usesSurfaceTree {
            mixedLayoutWorkspaces.formUnion(sessions.values.filter(\.supportsBrowserControls)
                .flatMap { $0.inventory.tabs.keys }.compactMap { placements[$0] })
        }
        for (id, workspace) in placements where Workspace.existing(byName: workspace) == nil {
            placements[id] = focus.workspace.name
        }
        scheduleRefresh()
    }

    func reconcileNativeHosts() {
        for app in MacApp.allAppsMap.values where excludesNativeDiscovery(processID: app.pid) {
            app.quarantineBrowserHost()
        }
        for window in MacWindow.allWindows where excludesNativeDiscovery(processID: window.app.pid) {
            window.relinquishToBrowser()
        }
    }

    /// All native logical selection paths (commands, gestures, mouse and sidebar)
    /// retire old browser work, including selecting the same native window again.
    func nativeSelectionChanged(_ id: SurfaceID?) {
        pendingNativeLayoutFocus = nil
        if isWinMuxRuntimeReady { restoredSelection = nil }
        if let id { surfaceTree.select(id); rememberSelection(id) }
        let leavingBrowser = hasBrowserSelection
        browserFocusDeadline = nil
        // Native selection must retire a disconnected browser target too.
        guard let generation = focusCoordinator.select(id) else { return }
        if leavingBrowser, let id {
            // A command can select the same native logical leaf that was current
            // before entering the browser. Dispatch even when the native tree's
            // before/after focus is unchanged; never await a browser fence.
            _ = NativeWindowSurfaceAdapter(surfaceID: id).requestFocus()
        }
        fenceBrowsers(generation: generation, target: id)
        scheduleRefresh()
    }

    private func rememberSelection(_ id: SurfaceID) {
        // Effective overflow stacks have no durable container identity. Keep
        // their recent selection during this session so focusing another tile
        // does not reset an unfocused tile to its first member.
        recentSelections.removeAll { $0 == id }
        recentSelections.insert(id, at: 0)
        if recentSelections.count > 10_000 { recentSelections.removeLast() }
    }

    /// Group activation restores either owner's latest live selection. Preserve
    /// the native fallback for groups without a recorded shared selection.
    func preferredSurface(in workspace: Workspace) -> SurfaceID? {
        guard usesSurfaceTree, restoredSelection == nil || isWinMuxRuntimeReady else { return nil }
        let belongs: (SurfaceID) -> Bool = { id in
            guard self.workspaceName(for: id) == workspace.name, self.isAvailable(id) else { return false }
            let browser = self.owner(of: id)?.inventory.tabs[id]
            // Automatic group activation picks a live tile. Restoring a Dock,
            // fullscreen or zoomed page remains an explicit sidebar selection.
            return browser?.hostMinimized != true && browser?.hostFullscreen != true && browser?.hostZoomed != true
        }
        if let recent = recentSelections.first(where: belongs) { return recent }
        if let native = workspace.toLiveFocus().windowOrNil?.surfaceID { return native }
        if let first = (surfaceTree.roots[workspace.name] ?? []).flatMap(\.surfaces).first(where: belongs) { return first }
        return placements.keys.filter(belongs).sorted { $0.description < $1.description }.first
    }

    private func fenceBrowsers(generation: UInt64, target: SurfaceID?) {
        for session in sessions.values {
            // The fence is revision/target independent on the owner; an empty
            // workspace still cancels the old tab focus without inventing an ID.
            guard let wireID = target ?? session.inventory.tabs.keys.first else { continue }
            session.supersedeFocus(generation: generation, target: wireID) { [weak self] outcome in
                guard outcome == .issued, let self, let target,
                      self.focusCoordinator.isCurrent(generation, target: target),
                      self.pendingNativeLayoutFocus == nil,
                      BrowserToolbarController.shared.focusedControlSurfaceID == nil,
                      !BrowserWindowDragController.shared.isDragging else { return }
                _ = NativeWindowSurfaceAdapter(surfaceID: target).requestFocus()
            }
        }
    }

    func tabCreationSession(profileID: UUID? = nil) -> BrowserSurfaceSession? {
        if let id = focusCoordinator.target, let owner = owner(of: id), owner.supportsTabCreation,
           profileID == nil || owner.inventory.tabs.keys.contains(where: { $0.browserProfileID == profileID }) { return owner }
        let capable = sessions.values.filter { $0.supportsTabCreation && $0.epoch != nil }
        if let profileID {
            let matching = capable.filter { $0.inventory.tabs.keys.contains { $0.browserProfileID == profileID } }
            if matching.count == 1 { return matching[0] }
            if !matching.isEmpty { return nil }
        }
        return capable.count == 1 ? capable[0] : nil
    }

    func placeCreatedBrowserTab(_ id: SurfaceID, in workspaceName: String, focusAddress: Bool, selectCreated: Bool, focusGeneration: UInt64) {
        placements[id] = workspaceName
        closedBrowserTabs.remove(id)
        if isWinMuxRuntimeReady { _ = Workspace.get(byName: workspaceName) }
        if usesSurfaceTree {
            mixedLayoutWorkspaces.insert(workspaceName)
            if surfaceTree.workspace(of: id) != nil { _ = surfaceTree.moveToRoot(id, in: workspaceName) }
            else { surfaceTree.reconcile([id] + (surfaceTree.roots[workspaceName] ?? []).flatMap(\.surfaces), in: workspaceName) }
        }
        if selectCreated {
            pendingBrowserTabSelections = [id: focusAddress]
            pendingBrowserTabFocusGeneration = focusGeneration
            completePendingBrowserTabSelections()
        }
        scheduleRefresh()
    }

    func owner(of id: SurfaceID) -> BrowserSurfaceSession? {
        let matches = sessions.values.filter { $0.inventory.tabs[id] != nil }
        // Concurrent live owners of a durable ID are ambiguous, never guess.
        return matches.count == 1 ? matches[0] : nil
    }

    func browserProcess(for id: SurfaceID) -> Int32? {
        guard let owner = owner(of: id), let connection = sessions.first(where: { $0.value === owner })?.key,
              let binding = processBindings[connection], excludesNativeDiscovery(processID: binding.pid) else { return nil }
        return binding.pid
    }

    func rows(in workspace: String) -> [WorkspaceSidebarItemViewModel] {
        sessions.values.flatMap { $0.inventory.tabs.values }
            .filter { placements[$0.surfaceID] == workspace && owner(of: $0.surfaceID) != nil }
            .sorted { $0.surfaceID.description < $1.surfaceID.description }
            .map { record in .init(kind: .browserTab(.init(
                surfaceID: record.surfaceID, workspaceName: workspace,
                title: record.title.isEmpty ? "New tab" : record.title,
                isFocused: focusCoordinator.target == record.surfaceID))) }
    }

    @discardableResult
    func select(_ id: SurfaceID, deferNativeFocusUntilLayout: Bool = false) -> SurfaceActionOutcome {
        restoredSelection = nil
        if isAvailable(id) {
            surfaceTree.select(id)
            pendingNativeLayoutFocus = nil
        }
        switch id {
            case .browserTab:
                guard let session = owner(of: id) else { return .unavailable }
                if let name = placements[id], let workspace = Workspace.existing(byName: name), workspace !== focus.workspace {
                    _ = workspace.focusWorkspace(restoringSurfaceSelection: false)
                }
                let result = BrowserTabSurfaceAdapter(surfaceID: id, session: session).requestFocus()
                if result == .issued {
                    rememberSelection(id)
                    browserFocusDeadline = Date().addingTimeInterval(1)
                    let generation = focusCoordinator.generation
                    for other in sessions.values where other !== session {
                        other.supersedeFocus(generation: generation, target: id) { [weak self, weak session] outcome in
                            guard outcome == .issued, let self, let session,
                                  self.focusCoordinator.target == id, self.owner(of: id) === session,
                                  let name = self.workspaceName(for: id),
                                  Workspace.existing(byName: name)?.isVisible == true,
                                  BrowserToolbarController.shared.focusedControlSurfaceID == nil,
                      !BrowserWindowDragController.shared.isDragging else { return }
                            // Another connection's fence may already have caused
                            // a reaffirmation (and advanced the dispatch clock).
                            // Each late fence still reaffirms the latest target.
                            _ = BrowserTabSurfaceAdapter(surfaceID: id, session: session).requestFocus()
                        }
                    }
                }
                scheduleRefresh()
                return result
            case .nativeWindow:
                browserFocusDeadline = nil
                guard let window = Window.get(bySurfaceID: id), let target = window.toLiveFocusOrNil() else { return .unavailable }
                guard let generation = focusCoordinator.select(id) else { return .unavailable }
                let result: SurfaceActionOutcome
                if deferNativeFocusUntilLayout || window.isHiddenInCorner || !target.workspace.isVisible {
                    result = setFocus(to: target, recordSurfaceIntent: false) ? .issued : .unavailable
                    if result == .issued {
                        pendingNativeLayoutFocus = (id, generation, foregroundProcessID())
                    }
                } else {
                    result = NativeWindowSurfaceAdapter(surfaceID: id).requestFocus()
                }
                if result == .issued { rememberSelection(id) }
                fenceBrowsers(generation: generation, target: id)
                scheduleRefresh()
                return result
        }
    }

    /// Group selection records intent immediately, but raising a parked native
    /// window before its destination frame is queued exposes its offscreen move.
    /// Return whether a deferred intent was handled, including a superseded one,
    /// so the session must not issue a second, stale native-focus request.
    func finishNativeGroupFocusAfterLayout() -> Bool {
        guard let pending = pendingNativeLayoutFocus else { return false }
        pendingNativeLayoutFocus = nil
        guard focusCoordinator.isCurrent(pending.generation, target: pending.id),
              let window = Window.get(bySurfaceID: pending.id), window.nodeWorkspace?.isVisible == true,
              focus.windowOrNil === window else { return true }
        let foreground = foregroundProcessID()
        guard foreground == pending.foregroundPID || foreground == window.app.pid else {
            // Retire the generation too: a late browser fence must not undo the
            // user's intervening activation after this pending request is gone.
            nativeSelectionChanged(nil)
            return true
        }
        window.nativeFocus()
        return true
    }

    @discardableResult
    func close(_ id: SurfaceID) -> SurfaceActionOutcome {
        if case .nativeWindow = id {
            return NativeWindowSurfaceAdapter(surfaceID: id).requestClose()
        } else if let session = owner(of: id) {
            return BrowserTabSurfaceAdapter(surfaceID: id, session: session).requestClose()
        }
        return .unavailable
    }

    func retireAbsentPinnedPage(_ id: SurfaceID) {
        guard case .browserTab = id, owner(of: id) == nil else { return }
        closedBrowserTabs.insert(id)
        placements.removeValue(forKey: id)
        surfaceTree.remove(id)
        unresolvedSidebarPinOwners.removeValue(forKey: id)
    }

    func organizedRows(native: [WorkspaceSidebarItemViewModel], in workspace: String) -> [WorkspaceSidebarItemViewModel] {
        let pinned: [WorkspaceSidebarItemViewModel] = []
        let pinnedIDs = Set(pinned.flatMap(\.surfaceIDs))
        guard usesSurfaceTree else { return pinned + native + rows(in: workspace).filter { $0.surfaceIDs.allSatisfy { !pinnedIDs.contains($0) } } }
        var available: [SurfaceID: WorkspaceSidebarItemViewModel] = [:]
        var ordered: [SurfaceID] = []
        var nativeOnlyRows: [WorkspaceSidebarItemViewModel] = []
        let importNativeGroups = surfaceTree.roots[workspace] == nil
        var nativeGroups: [[SurfaceID]] = []
        func collect(_ item: WorkspaceSidebarItemViewModel) {
            switch item.kind {
            case .window(let window):
                if let owner = Window.get(bySurfaceID: window.surfaceID), !participatesInSharedTiling(owner) {
                    nativeOnlyRows.append(item)
                    return
                }
                ordered.append(window.surfaceID)
                available[window.surfaceID] = .init(kind: .surface(.init(surfaceID: window.surfaceID,
                    title: window.title ?? window.appName, appName: window.appName, isFocused: window.isFocused,
                    appBundleId: window.appBundleId, appBundlePath: window.appBundlePath)))
            case .browserTab(let tab):
                ordered.append(tab.surfaceID)
                let path = browserProcess(for: tab.surfaceID).flatMap { NSRunningApplication(processIdentifier: $0)?.bundleURL?.path }
                available[tab.surfaceID] = .init(kind: .surface(.init(surfaceID: tab.surfaceID,
                    title: tab.title, appName: "WinMux Browser", isFocused: tab.isFocused,
                    appBundleId: "com.jameslyons.winmux.browser.alpha", appBundlePath: path)))
            case .tabGroup(let group):
                nativeGroups.append(group.tabs.map(\.surfaceID))
                group.tabs.forEach { collect(.init(kind: .window($0))) }
            case .surface, .surfaceGroup, .pinnedBrowserTab: break
            }
        }
        (native + rows(in: workspace)).forEach(collect)
        unresolvedNativeItems.subtract(available.keys)
        // Native fullscreen/minimize transitions must not erase a saved mixed
        // stack. Floating conversion intentionally leaves shared organization.
        let temporaryNative = Set((surfaceTree.roots[workspace] ?? []).flatMap(\.surfaces).filter {
            guard let window = Window.get(bySurfaceID: $0), window.nodeWorkspace?.name == workspace else { return false }
            return !window.isFloating && !participatesInSharedTiling(window)
        })
        surfaceTree.reconcile(ordered, in: workspace,
                              retaining: Set(placements.filter { $0.value == workspace }.map(\.key))
                                .union(unresolvedNativeItems).union(temporaryNative))
        if importNativeGroups {
            if let owner = Workspace.existing(byName: workspace) {
                importNativeOrganization(owner.rootTilingContainer, available: Set(ordered), in: workspace)
            } else {
                nativeGroups.forEach { surfaceTree.importStack($0, in: workspace) }
            }
            if let selected = focusCoordinator.target ?? focus.windowOrNil?.surfaceID { surfaceTree.select(selected) }
        }
        func project(_ node: SurfaceTreeNode) -> [WorkspaceSidebarItemViewModel] {
            switch node {
            case .surface(let id):
                if pinnedIDs.contains(id) { return [] }
                if let row = available[id] { return [row] }
                return unresolvedNativeItems.contains(id)
                    ? [.init(kind: .surface(.init(surfaceID: id, title: "Waiting for owner", appName: "", isFocused: false)))] : []
            case .group(let id, let children):
                let visible = children.flatMap(project)
                guard !visible.isEmpty else { return [] }
                // Match the native sidebar: split containers arrange panes but
                // only tab stacks add a header. Layout changes alter snapshots.
                return (surfaceTree.layouts[id] ?? .stack) == .stack ? [.init(kind: .surfaceGroup(id, visible))] : visible
            }
        }
        return pinned + (surfaceTree.roots[workspace] ?? []).flatMap(project) + nativeOnlyRows
    }

    private func participatesInSharedTiling(_ window: Window) -> Bool {
        window.parent is TilingContainer && !window.isFullscreen &&
            window.lastKnownNativeFullscreen != true && window.lastKnownNativeMinimized != true
    }

    private func importNativeOrganization(_ root: TilingContainer, available: Set<SurfaceID>, in workspace: String) {
        let native = nativeOrganization(root, available: available)
        _ = surfaceTree.importOrganization(native.nodes, in: workspace, layouts: native.layouts,
                                           activeSurfaces: native.active, weights: native.weights)
    }

    private func nativeOrganization(_ root: TilingContainer, available: Set<SurfaceID>)
        -> (nodes: [SurfaceTreeNode], layouts: [UUID: SurfaceContainerLayout], active: [UUID: SurfaceID], weights: [String: Double]) {
        var layouts: [UUID: SurfaceContainerLayout] = [:]
        var active: [UUID: SurfaceID] = [:]
        var weights: [String: Double] = [:]
        func key(_ node: SurfaceTreeNode) -> String {
            switch node {
            case .surface(let id): id.description
            case .group(let id, _): "group:" + id.uuidString.lowercased()
            }
        }
        func project(_ node: TreeNode) -> SurfaceTreeNode? {
            if let window = node as? Window { return available.contains(window.surfaceID) ? .surface(window.surfaceID) : nil }
            guard let container = node as? TilingContainer else { return nil }
            let children = container.children.compactMap { child -> SurfaceTreeNode? in
                guard let projected = project(child) else { return nil }
                if container.layout == .tiles {
                    weights[key(projected)] = min(30000, max(1, Double(child.getWeight(container.orientation))))
                }
                return projected
            }
            guard children.count > 1 else { return children.first }
            let id = UUID()
            layouts[id] = container.layout == .tabGroup ? .stack : (container.orientation == .h ? .horizontal : .vertical)
            if let selected = container.tabActiveWindow?.surfaceID, children.flatMap(\.surfaces).contains(selected) { active[id] = selected }
            return .group(id, children)
        }
        let nodes: [SurfaceTreeNode]
        if root.layout == .tiles && root.orientation == .h {
            nodes = root.children.compactMap { child in
                guard let projected = project(child) else { return nil }
                weights[key(projected)] = min(30000, max(1, Double(child.getWeight(root.orientation))))
                return projected
            }
        } else { nodes = project(root).map { [$0] } ?? [] }
        return (nodes, layouts, active, weights)
    }

    func workspaceName(forGroup id: UUID) -> String? { surfaceTree.workspace(ofGroup: id) }

    func sidebarGroupLayout(_ id: UUID) -> SurfaceContainerLayout { surfaceTree.layouts[id] ?? .stack }

    func canMoveSurface(_ id: SurfaceID) -> Bool {
        guard usesSurfaceTree, isAvailable(id), let workspace = surfaceTree.workspace(of: id),
              workspaceName(for: id) == workspace, Workspace.existing(byName: workspace)?.isArchived == false else { return false }
        switch id {
        case .browserTab: return owner(of: id)?.supportsLayout == true
        case .nativeWindow: return Window.get(bySurfaceID: id).map(participatesInSharedTiling) == true
        }
    }

    func canMoveGroup(_ id: UUID) -> Bool {
        guard usesSurfaceTree, let group = surfaceTree.group(id), !group.surfaces.isEmpty else { return false }
        return group.surfaces.allSatisfy(canMoveSurface)
    }

    /// Preflight the complete subtree before synchronously moving either owner.
    /// Intermediate leaf moves would dissolve the stack and prune its metadata.
    @discardableResult
    func moveGroup(_ id: UUID, to destination: Workspace) -> Bool {
        guard !destination.isArchived, canMoveGroup(id), let group = surfaceTree.group(id),
              let sourceName = surfaceTree.workspace(ofGroup: id), sourceName != destination.name,
              let source = Workspace.existing(byName: sourceName) else { return false }
        let affected = Set([sourceName, destination.name])
        guard let reservations = organizationReservations(in: affected) else { return false }
        var candidate = surfaceTree
        if candidate.roots[destination.name] == nil {
            // A new or not-yet-projected destination must adopt its actual native
            // hierarchy in the candidate, never mutate live state during preflight.
            let native = destination.rootTilingContainer.allLeafWindowsRecursive.filter(participatesInSharedTiling)
            let browser = placements.filter { $0.value == destination.name }.map(\.key).sorted { $0.description < $1.description }
            guard native.allSatisfy({ $0.toLiveFocusOrNil() != nil }),
                  browser.allSatisfy({ isAvailable($0) && owner(of: $0)?.supportsLayout == true }) else { return false }
            let nativeIDs = native.map(\.surfaceID)
            candidate.reconcile(nativeIDs + browser, in: destination.name)
            let imported = nativeOrganization(destination.rootTilingContainer, available: Set(nativeIDs))
            if !imported.nodes.isEmpty {
                guard candidate.importOrganization(imported.nodes, in: destination.name, layouts: imported.layouts,
                                                   activeSurfaces: imported.active, weights: imported.weights) else { return false }
            }
        }
        guard candidate.moveGroupToRoot(id, in: destination.name),
              reservations.allSatisfy({ candidate.workspace(of: $0.key) == $0.value }),
              let data = try? JSONEncoder().encode(candidate),
              (try? JSONDecoder().decode(SurfaceTree.self, from: data)) != nil else { return false }
        let members = Set(group.surfaces)
        let nativeWindows = group.surfaces.compactMap { Window.get(bySurfaceID: $0) }
        guard nativeWindows.count == group.surfaces.filter({ if case .nativeWindow = $0 { return true }; return false }).count,
              nativeWindows.allSatisfy({ $0.toLiveFocusOrNil() != nil && participatesInSharedTiling($0) }) else { return false }
        let movedSelection = (focusCoordinator.target ?? focus.windowOrNil?.surfaceID).map(members.contains) == true
        syncClosedWindowsCacheToCurrentWorld()
        suppressPostDragAxObserverEvents(for: nativeWindows.map(\.windowId))
        for window in nativeWindows {
            let binding = workspaceAppendBindingData(targetWorkspace: destination, index: INDEX_BIND_LAST)
            window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
        }
        for member in group.surfaces { if case .browserTab = member { placements[member] = destination.name } }
        surfaceTree = candidate
        mixedLayoutWorkspaces.formUnion(affected)
        restoredSelection = nil
        if movedSelection {
            let remaining = (surfaceTree.roots[sourceName] ?? []).flatMap(\.surfaces).first(where: isAvailable)
            let focusedRemaining = remaining.map { select($0) == .issued } ?? false
            if !focusedRemaining {
                _ = source.focusWorkspace()
                nativeSelectionChanged(nil)
            }
        }
        scheduleRefresh()
        return true
    }

    /// Shared organization dispatches owner layout only after capability checks.
    /// Native owners are revalidated; browser profile identity is preserved.
    func organize(_ id: SurfaceID, before target: SurfaceID? = nil, earlier: Bool? = nil, groupWithSelection: Bool = false, layout: SurfaceContainerLayout = .stack) {
        guard usesSurfaceTree, isAvailable(id) else { return }
        if let target {
            guard isAvailable(target) else { return }
            if workspaceName(for: id) != workspaceName(for: target) {
                guard let name = workspaceName(for: target), let destination = Workspace.existing(byName: name),
                      moveSurfaceToWorkspace(id, destination, CmdIo(stdin: .emptyStdin),
                          focusFollowsSurface: false, failIfNoop: false, controller: self) else { return }
            }
            _ = surfaceTree.move(id, before: target)
        } else if let earlier { _ = surfaceTree.reorder(id, earlier: earlier) }
        else if groupWithSelection, let target = focusCoordinator.target, isAvailable(target) {
            if surfaceTree.group(id, with: target, layout: layout), let workspace = surfaceTree.workspace(of: id),
               sessions.values.allSatisfy({ $0.supportsLayout }) {
                mixedLayoutWorkspaces.insert(workspace)
            }
        }
        scheduleRefresh()
    }

    func ungroup(_ id: UUID) { _ = surfaceTree.ungroup(id); scheduleRefresh() }

    /// Structural commands must never edit the old native tree behind a browser
    /// selection. Validate the owners and candidate snapshot before committing.
    func editOrganization(of id: SurfaceID, _ edit: (inout SurfaceTree) -> Bool) -> Bool {
        guard usesSurfaceTree, isAvailable(id), let workspace = surfaceTree.workspace(of: id),
              let reservations = organizationReservations(in: [workspace]) else { return false }
        var candidate = surfaceTree
        guard edit(&candidate), reservations.allSatisfy({ candidate.workspace(of: $0.key) == $0.value }) else { return false }
        if let selected = focusCoordinator.target { candidate.select(selected) }
        // The same depth/identity limits apply to new edits and restored trees.
        guard let data = try? JSONEncoder().encode(candidate),
              (try? JSONDecoder().decode(SurfaceTree.self, from: data)) != nil else { return false }
        surfaceTree = candidate
        mixedLayoutWorkspaces.insert(workspace)
        scheduleRefresh()
        return true
    }

    /// Prepare the entire cross-workspace edit before changing owner membership.
    /// This synchronous commit has no suspension between validation and binding.
    func editOrganization(of id: SurfaceID, movingTo destination: Workspace,
                          _ edit: (inout SurfaceTree) -> Bool) -> Bool {
        guard usesSurfaceTree, isAvailable(id), let source = surfaceTree.workspace(of: id),
              workspaceName(for: id) == source else { return false }
        if source == destination.name { return editOrganization(of: id, edit) }
        let affected = Set([source, destination.name])
        guard let reservations = organizationReservations(in: affected) else { return false }
        var candidate = surfaceTree
        guard candidate.moveToRoot(id, in: destination.name), edit(&candidate),
              reservations.allSatisfy({ candidate.workspace(of: $0.key) == $0.value }) else { return false }
        if let selected = focusCoordinator.target { candidate.select(selected) }
        guard let data = try? JSONEncoder().encode(candidate),
              (try? JSONDecoder().decode(SurfaceTree.self, from: data)) != nil else { return false }
        switch id {
        case .browserTab: placements[id] = destination.name
        case .nativeWindow:
            guard let window = Window.get(bySurfaceID: id), window.toLiveFocusOrNil() != nil else { return false }
            syncClosedWindowsCacheToCurrentWorld()
            suppressPostDragAxObserverEvents(for: [window.windowId])
            if window.isFloating { window.bind(to: destination, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST) }
            else {
                let binding = workspaceAppendBindingData(targetWorkspace: destination, index: INDEX_BIND_LAST)
                window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
            }
        }
        surfaceTree = candidate
        mixedLayoutWorkspaces.formUnion(affected)
        scheduleRefresh()
        return true
    }

    /// A restored native identity may still be waiting for its real app. It is
    /// a durable reservation, not an owner that can veto unrelated live edits.
    /// Once a matching native binding has appeared, normal close/stale-owner
    /// validation applies even if its row has not reached the sidebar yet.
    private func retireResolvedNativeReservations() {
        unresolvedNativeItems = unresolvedNativeItems.filter { Window.get(bySurfaceID: $0) == nil }
    }

    private func organizationReservations(in workspaces: Set<String>) -> [SurfaceID: String]? {
        retireResolvedNativeReservations()
        var reservations: [SurfaceID: String] = [:]
        for name in workspaces {
            let nodes = surfaceTree.roots[name] ?? []
            for member in nodes.flatMap(\.surfaces) {
                if case .nativeWindow = member, unresolvedNativeItems.contains(member) {
                    reservations[member] = name
                    continue
                }
                guard isAvailable(member), workspaceName(for: member) == name else { return nil }
                if case .browserTab = member, owner(of: member)?.supportsLayout != true { return nil }
            }
        }
        return reservations
    }

    func isAvailable(_ id: SurfaceID) -> Bool {
        switch id {
        case .nativeWindow: Window.get(bySurfaceID: id)?.toLiveFocusOrNil() != nil
        case .browserTab: owner(of: id) != nil
        }
    }

    func moveBrowserSurface(_ id: SurfaceID, to workspace: String) {
        guard usesSurfaceTree, let session = owner(of: id), session.supportsLayout else { return }
        // A workspace move needs owner visibility even without a prior split.
        // Activate both sides so tabs sharing a browser host can separate safely.
        if let old = placements[id] { mixedLayoutWorkspaces.insert(old) }
        mixedLayoutWorkspaces.insert(workspace)
        placements[id] = workspace
        _ = surfaceTree.moveToRoot(id, in: workspace)
        scheduleRefresh()
    }

    func workspaceName(for id: SurfaceID) -> String? {
        if case .browserTab = id { return placements[id] }
        return Window.get(bySurfaceID: id)?.nodeWorkspace?.name ?? surfaceTree.workspace(of: id)
    }

    var knownSurfaces: Set<SurfaceID> {
        Set(surfaceTree.roots.values.flatMap { $0.flatMap(\.surfaces) })
            .union(placements.keys)
            .union(Workspace.all.flatMap { $0.allLeafWindowsRecursive.map(\.surfaceID) })
    }

    @discardableResult
    func adoptPinnedSurface(_ id: SurfaceID, into workspace: String) -> Bool {
        if case .browserTab = id {
            if let old = placements[id] { mixedLayoutWorkspaces.insert(old) }
            mixedLayoutWorkspaces.insert(workspace)
            placements[id] = workspace
            _ = surfaceTree.moveToRoot(id, in: workspace)
        } else if let destination = Workspace.existing(byName: workspace) {
            guard let window = Window.get(bySurfaceID: id), canAdoptNativePinWindow(window) else { return false }
            if window.nodeWorkspace != destination {
                syncClosedWindowsCacheToCurrentWorld()
                suppressPostDragAxObserverEvents(for: [window.windowId])
                guard moveSurfaceToWorkspace(id, destination, CmdIo(stdin: .emptyStdin), focusFollowsSurface: false, failIfNoop: false, controller: self) else { return false }
            }
            if participatesInSharedTiling(window) { _ = surfaceTree.moveToRoot(id, in: workspace) }
            else { surfaceTree.remove(id) }
        } else { return false }
        scheduleRefresh()
        return true
    }

    func isAwaitingNativePinBinding(_ id: SurfaceID) -> Bool { unresolvedNativeItems.contains(id) }

    func retireMissingNativePinBinding(_ id: SurfaceID) {
        guard Window.get(bySurfaceID: id) == nil else { return }
        unresolvedNativeItems.remove(id)
        surfaceTree.remove(id)
    }

    func didMoveNativeSurface(_ id: SurfaceID, to workspace: String) {
        guard usesSurfaceTree else { return }
        if let old = surfaceTree.workspace(of: id), mixedLayoutWorkspaces.contains(old) {
            mixedLayoutWorkspaces.insert(workspace)
        }
        _ = surfaceTree.moveToRoot(id, in: workspace)
        scheduleRefresh()
    }

    /// Native floating conversion changes membership immediately, while other
    /// owners keep their durable IDs, organization and current selection.
    func nativeTilingStateChanged(_ window: Window) {
        guard usesSurfaceTree else { return }
        unresolvedNativeItems.remove(window.surfaceID)
        if participatesInSharedTiling(window), let workspace = window.nodeWorkspace {
            let existing = (surfaceTree.roots[workspace.name] ?? []).flatMap(\.surfaces)
            surfaceTree.reconcile(existing + [window.surfaceID], in: workspace.name)
            if focusCoordinator.target == window.surfaceID { surfaceTree.select(window.surfaceID) }
        } else {
            surfaceTree.remove(window.surfaceID)
        }
        scheduleRefresh()
    }

    func containsBrowserItems(in workspace: String) -> Bool {
        usesSurfaceTree && (browserSidebarPins.contains(where: { $0.workspaceName == workspace }) || placements.values.contains(workspace) ||
            (surfaceTree.roots[workspace] ?? []).flatMap(\.surfaces).contains(where: unresolvedNativeItems.contains))
    }

    func moveWorkspaceContents(from source: String, to target: String) {
        guard source != target else { return }
        for (id, workspace) in placements where workspace == source { placements[id] = target }
        for index in browserSidebarPins.indices where browserSidebarPins[index].workspaceName == source {
            browserSidebarPins[index].workspaceName = target
        }
        if mixedLayoutWorkspaces.remove(source) != nil { mixedLayoutWorkspaces.insert(target) }
        surfaceTree.mergeWorkspace(source, into: target)
        scheduleRefresh()
    }

    func minimumSizes(in workspace: Workspace) -> [SurfaceID: SurfaceMinimumSize] {
        var result: [SurfaceID: SurfaceMinimumSize] = [:]
        for id in (surfaceTree.roots[workspace.name] ?? []).flatMap(\.surfaces) {
            if case .browserTab = id {
                let minimum = owner(of: id)?.inventory.tabs[id]?.hostMinimumSize ?? .init(width: 500, height: 400)
                if owner(of: id)?.supportsBrowserControls == true {
                    result[id] = .init(width: min(30000, max(160, minimum.width) + BrowserPageChromeGeometry.widthOverhead),
                                       height: min(30000, max(120, minimum.height) + BrowserPageChromeGeometry.heightOverhead))
                } else {
                    result[id] = minimum
                }
            } else {
                result[id] = observedNativeMinimums[id] ?? .init(width: 80, height: 80)
            }
        }
        return result
    }

    func hasMixedLayout(in workspace: Workspace) -> Bool { mixedLayoutWorkspaces.contains(workspace.name) }

    /// Rendering and resizing must use the same tree of currently claimed panes.
    /// The durable tree keeps reservations until their real native owner returns.
    func liveLayoutTree(in workspace: Workspace) -> SurfaceTree {
        retireResolvedNativeReservations()
        var livePlan = surfaceTree
        for id in (surfaceTree.roots[workspace.name] ?? []).flatMap(\.surfaces) {
            // Keep temporary native absence in the saved tree, but never place
            // floating, minimized, fullscreen or unresolved windows as tiles.
            let browser = owner(of: id)?.inventory.tabs[id]
            if browser?.hostMinimized == true || browser?.hostFullscreen == true || browser?.hostZoomed == true ||
                unresolvedNativeItems.contains(id) || Window.get(bySurfaceID: id).map({ !participatesInSharedTiling($0) }) == true {
                livePlan.remove(id)
            }
        }
        return livePlan
    }

    func plannedSurfaces(in workspace: Workspace) -> [SurfacePlacement] {
        let livePlan = liveLayoutTree(in: workspace)
        let rect = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        return livePlan.placements(in: workspace.name, frame: .init(x: Int(rect.topLeftX.rounded()),
            y: Int(rect.topLeftY.rounded()), width: Int(rect.width.rounded()), height: Int(rect.height.rounded())),
            visible: workspace.isVisible && !hasNativeFullscreenLayout(in: workspace), minimumSizes: minimumSizes(in: workspace), selectedSurface: focusCoordinator.target, recentSelections: recentSelections)
    }

    func isHiddenInMixedLayout(_ id: SurfaceID, workspace: Workspace) -> Bool {
        guard TrayMenuModel.shared.isEnabled, mixedLayoutWorkspaces.contains(workspace.name) else { return false }
        return plannedSurfaces(in: workspace).first { $0.surfaceID == id }?.visible == false
    }

    func hiddenSurfacesInMixedLayout(in workspace: Workspace) -> Set<SurfaceID> {
        guard TrayMenuModel.shared.isEnabled, mixedLayoutWorkspaces.contains(workspace.name) else { return [] }
        return Set(plannedSurfaces(in: workspace).filter { !$0.visible }.map(\.surfaceID))
    }

    private func hasNativeFullscreenLayout(in workspace: Workspace) -> Bool {
        workspace.rootTilingContainer.allTabbedContainersRecursive.contains(where: \.hasFullscreenTab) ||
            workspace.rootTilingContainer.mostRecentWindowRecursive?.isFullscreen == true
    }

    func applyNativeLayout(in workspace: Workspace) async throws -> Bool {
        guard TrayMenuModel.shared.isEnabled, usesSurfaceTree, BrowserNativeManagement.lease != nil, mixedLayoutWorkspaces.contains(workspace.name) else { return false }
        guard !hasNativeFullscreenLayout(in: workspace) else { return false }
        try await workspace.layoutFloatingWindowsForSharedLayout()
        let placements = plannedSurfaces(in: workspace)
        for placement in placements {
            guard let window = Window.get(bySurfaceID: placement.surfaceID), window.nodeWorkspace === workspace else { continue }
            if BrowserWindowDragController.shared.isMovingNativeSurface(placement.surfaceID) { continue }
            if placement.visible {
                let frame = placement.frame
                let rect = Rect(topLeftX: Double(frame.x), topLeftY: Double(frame.y), width: Double(frame.width), height: Double(frame.height))
                if !canReuseLastAppliedWindowFrame(previousPhysicalRect: window.lastAppliedLayoutPhysicalRect, nextPhysicalRect: rect) {
                    if let native = window as? MacWindow {
                        let actual = try await window.applyObservedSharedLayoutFrame(rect, apply: {
                            // AX has no universal minimum-size attribute. Observe the
                            // owner's result after its serialized frame write, never
                            // infer a limit from a stale pre-write window size.
                            try await native.setAxFrameBlocking(rect.topLeftCorner, CGSize(width: frame.width, height: frame.height))
                        }, observe: { try await native.getAxRect() })
                        if let actual, window.lastAppliedLayoutPhysicalRect == rect,
                               Window.get(bySurfaceID: placement.surfaceID) === window,
                               actual.width.isFinite, actual.height.isFinite,
                               (1...30000).contains(actual.width), (1...30000).contains(actual.height),
                               actual.width > rect.width + 1 || actual.height > rect.height + 1 {
                                let old = observedNativeMinimums[placement.surfaceID] ?? .init(width: 80, height: 80)
                                let minimum = SurfaceMinimumSize(width: actual.width > rect.width + 1 ? Int(actual.width.rounded(.up)) : old.width,
                                    height: actual.height > rect.height + 1 ? Int(actual.height.rounded(.up)) : old.height)
                                if minimum.isValid, minimum != old {
                                    observedNativeMinimums[placement.surfaceID] = minimum
                                    scheduleRefresh()
                                }
                        }
                    } else {
                        window.lastAppliedLayoutPhysicalRect = rect
                        window.lastAppliedLayoutVirtualRect = rect
                        window.setAxFrame(rect.topLeftCorner, CGSize(width: frame.width, height: frame.height))
                    }
                }
            } else if let native = window as? MacWindow {
                try await native.hideInCorner(.bottomRightCorner)
                window.lastAppliedLayoutPhysicalRect = nil
                window.lastAppliedLayoutVirtualRect = nil
            }
        }
        return !placements.isEmpty
    }

    func publishBrowserLayouts(force: Bool = false) {
        guard usesSurfaceTree, BrowserNativeManagement.lease != nil else {
            BrowserToolbarController.shared.hideAll()
            return
        }
        let placements = TrayMenuModel.shared.isEnabled ? Workspace.all.filter { mixedLayoutWorkspaces.contains($0.name) }.flatMap(plannedSurfaces) : []
        updateBrowserToolbars(placements)
        for session in sessions.values where session.supportsLayout {
            let owned = placements.filter { owner(of: $0.surfaceID) === session }
            let hosts = browserHostPlacements(owned, hasNativeToolbar: session.supportsBrowserControls,
                                              bodyFrameOverrides: BrowserWindowDragController.shared.bodyFrameOverrides)
            if force { session.invalidateLayoutAcknowledgement() }
            let target = focusCoordinator.target, generation = focusCoordinator.generation
            session.requestLayout(hosts) { [weak self, weak session] reply in
                guard reply == .issued, TrayMenuModel.shared.isEnabled, let self, let session, let target,
                      self.focusCoordinator.isCurrent(generation, target: target),
                      let workspaceName = self.workspaceName(for: target),
                      let workspace = Workspace.existing(byName: workspaceName), workspace.isVisible,
                      self.plannedSurfaces(in: workspace).contains(where: { $0.surfaceID == target && $0.visible }),
                      BrowserToolbarController.shared.focusedControlSurfaceID == nil,
                      !BrowserWindowDragController.shared.isDragging else { return }
                if case .nativeWindow = target {
                    guard self.pendingNativeLayoutFocus == nil else { return }
                    _ = NativeWindowSurfaceAdapter(surfaceID: target).requestFocus()
                    return
                }
                guard self.owner(of: target) === session else { return }
                // A transfer can replace the selected tab's former native host.
                // Reaffirm only the still-current browser target after dispatch.
                _ = BrowserTabSurfaceAdapter(surfaceID: target, session: session).requestFocus()
            }
        }
    }

    func scheduleRefresh() { refreshScheduler.schedule() }

    /// Inventory may arrive while native discovery and saved-layout restoration
    /// are still running. Keep that work pending, then publish it before startup
    /// reports ready, even if the browser sends no further inventory event.
    func runtimeDidBecomeReady() async {
        guard isWinMuxRuntimeReady else { return }
        let interval = signposter.beginInterval("Browser startup presentation")
        defer { signposter.endInterval("Browser startup presentation", interval) }
        await refreshScheduler.resumePendingRefreshAndWaitForPass()
    }

    private func performScheduledRefresh() async {
        if previewWindow != nil { refreshPreview() }
        guard isWinMuxRuntimeReady else { return }
        // Restore selection before its layout pass, as the old queued sidebar
        // session did. A selection-triggered refresh coalesces into one follow-up.
        if let selected = restoredSelection, isAvailable(selected) { _ = select(selected) }
        if !mixedLayoutWorkspaces.isEmpty, let token = RunSessionGuard.isServerEnabled {
            do {
                // Browser inventory and validated surface edits already contain
                // their complete model changes. They do not need unrelated AX
                // discovery or an outgoing app focus query. The light session
                // also publishes sidebar/chrome and checkpoints exactly once.
                try await runLightSession(
                    .onTabSwitched, token,
                    shouldSchedulePostRefresh: false,
                    synchronizeNativeFocus: false
                ) {}
            } catch is CancellationError {
                return
            } catch {
                showWorkspaceSidebarError(error.localizedDescription)
            }
        } else {
            await updateWorkspaceSidebarModel()
            RestartSessionController.shared.checkpoint()
        }
    }

    /// Explicit staging mode: real sidebar, real authenticated tabs/actions,
    /// no AX observers, shortcuts, native layouts, config or session writes.
    public func showIsolatedSidebar() {
        guard previewWindow == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 80, y: 100, width: 280, height: 660),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "WinMux Browser Sidebar"
        window.isReleasedWhenClosed = false
        previewWindow = window
        usesSurfaceTree = true
        window.contentView = NSHostingView(rootView: BrowserSidebarPreviewView(state: previewState,
            actions: WorkspaceSidebarActions(send: { [weak self] action in
                switch action {
                    case .newBrowserTab(let workspace): _ = self?.openBrowserTab(workspaceName: workspace)
                    case .pinBrowserTab(let id): _ = self?.pinBrowserTab(id)
                    case .unpinBrowserTab(let id): self?.unpinBrowserTab(id)
                    case .selectPinnedBrowserTab(let id): _ = self?.selectPinnedBrowserTab(id)
                    case .movePinnedBrowserTab(let id, let workspace): self?.movePinnedBrowserTab(id, to: workspace)
                    case .selectSurface(let id): _ = self?.select(id)
                    case .closeSurface(let id): self?.close(id)
                    case .reorderSurface(let id, let earlier): self?.organize(id, earlier: earlier)
                    case .moveSurfaceBefore(let id, let target): self?.organize(id, before: target)
                    case .groupSurfaceWithSelection(let id): self?.organize(id, groupWithSelection: true)
                    case .ungroupSurfaces(let id): self?.ungroup(id)
                    default: break
                }
            })))
        refreshPreview()
        window.makeKeyAndOrderFront(nil)
    }

    private func refreshPreview() {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.visibleWidth = 280
        snapshot.configuration.expandedWidth = 280
        snapshot.configuration.collapsedWidth = 40
        snapshot.configuration.isCompactMode = false
        snapshot.configuration.chromeStyle = .solid
        snapshot.configuration.showsBrowserControls = true
        snapshot.projects = [.init(id: workspaceProjectDefaultId, displayName: "WinMux Alpha", colorHex: nil)]
        snapshot.workspaces = [.init(name: "browser-alpha", projectId: workspaceProjectDefaultId,
            displayName: "Browser tabs", sidebarLabel: "", isGeneratedName: false,
            monitorScopeId: workspaceSidebarDefaultScopeId, monitorName: "", isFocused: true, isVisible: true,
            items: organizedRows(native: [], in: "browser-alpha"))]
        previewState.snapshot = snapshot
    }
}

extension Window {
    /// Only geometry-changing sessions probe native minimum sizes again. A normal
    /// group/tab return queues its previously verified size without serial AX waits.
    @MainActor func applyObservedSharedLayoutFrame(
        _ rect: Rect,
        apply: @MainActor () async throws -> Void,
        observe: @MainActor () async throws -> Rect?,
    ) async throws -> Rect? {
        if refreshSessionEvent?.canReuseLastAppliedWindowFrames == true,
           lastConfirmedSharedLayoutSize == rect.size {
            lastAppliedLayoutPhysicalRect = rect
            lastAppliedLayoutVirtualRect = rect
            setAxFrame(rect.topLeftCorner, rect.size)
            return nil
        }
        var actual: Rect?
        lastConfirmedSharedLayoutSize = nil
        try await applySharedLayoutFrame(rect) {
            try await apply()
            let observationToken = nativeStateObservationToken()
            actual = try await observe()
            try checkCancellation()
            if lastAppliedLayoutPhysicalRect == rect, nativeStateObservationToken() == observationToken {
                lastConfirmedSharedLayoutSize = actual?.size == rect.size ? rect.size : nil
            }
        }
        return actual
    }

    /// AX frame application can be interrupted halfway through a startup or
    /// command session. A requested frame must not remain cached as completed.
    @MainActor func applySharedLayoutFrame(_ rect: Rect, apply: @MainActor () async throws -> Void) async throws {
        lastAppliedLayoutPhysicalRect = rect
        lastAppliedLayoutVirtualRect = rect
        do { try await apply() }
        catch {
            if lastAppliedLayoutPhysicalRect == rect {
                lastAppliedLayoutPhysicalRect = nil
                lastAppliedLayoutVirtualRect = nil
            }
            throw error
        }
    }
}

@MainActor private final class BrowserSidebarPreviewState: ObservableObject {
    @Published var snapshot = WorkspaceSidebarSnapshot.empty
}

private struct BrowserSidebarPreviewView: View {
    @ObservedObject var state: BrowserSidebarPreviewState
    let actions: WorkspaceSidebarActions
    var body: some View { WorkspaceSidebarView(snapshot: state.snapshot, actions: actions) }
}

/// Keep one browser model/layout pass active across suspension points. Inventory
/// bursts during that pass request one trailing pass instead of overlapping tasks.
@MainActor
final class CoalescedBrowserRefreshScheduler {
    private let isReady: @MainActor () -> Bool
    private let refresh: @MainActor () async -> Void
    private var requested = false
    private var requestedGeneration: UInt64 = 0
    private var completedGeneration: UInt64 = 0
    private var passWaiters: [(generation: UInt64, continuation: CheckedContinuation<Void, Never>)] = []
    private var task: Task<Void, Never>?

    init(isReady: @escaping @MainActor () -> Bool = { true }, refresh: @escaping @MainActor () async -> Void) {
        self.isReady = isReady
        self.refresh = refresh
    }

    func schedule() {
        requested = true
        requestedGeneration += 1
        resumePendingRefresh()
    }

    /// Wait only for requests already queued by the caller. Later browser
    /// inventory must not make startup depend on the whole browser becoming idle.
    func resumePendingRefreshAndWaitForPass() async {
        guard isReady(), completedGeneration < requestedGeneration else { return }
        let generation = requestedGeneration
        resumePendingRefresh()
        await withCheckedContinuation { continuation in
            passWaiters.append((generation, continuation))
        }
    }

    func resumePendingRefresh() {
        guard requested, isReady(), task == nil else { return }
        task = Task { @MainActor in
            while self.requested, self.isReady() {
                let generation = self.requestedGeneration
                self.requested = false
                await self.refresh()
                self.completedGeneration = generation
                let completed = self.passWaiters.filter { $0.generation <= generation }
                self.passWaiters.removeAll { $0.generation <= generation }
                completed.forEach { $0.continuation.resume() }
            }
            self.task = nil
        }
    }

    func waitUntilIdle() async { await task?.value }
}
