import Common
import AppKit
import SwiftUI
import WorkspaceCore

/// One value snapshot per sidebar refresh; never reused across inventory changes.
struct BrowserSidebarProjection {
    var rowsByWorkspace: [String: [WorkspaceSidebarItemViewModel]] = [:]
    var appPaths: [SurfaceID: String] = [:]
    var selectedSurfaces: Set<SurfaceID> = []
}

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

    var privateSurfaces: Set<SurfaceID> = []
    var incognitoReturnWorkspaces: [WorkspaceProjectId: String] = [:]
    var savedViews: [SavedView] = []
    var legacyBrowserPins: [BrowserSidebarPin] = []
    var legacyAppPins: [NativeAppSidebarPin] = []
    var browserMemberOrder: [UUID] = []
    var appMemberOrder: [UUID] = []
    var pinShelves: [SpacePinShelf] = []
    var spacePinnedGroups: [SpacePinnedGroup] = []
    var browserProfiles: [WorkspaceBrowserProfile] = []
    var browserProfileBySpace: [String: UUID] = [:]
    var pendingNativePinLaunches: [UUID: UUID] = [:]
    var failedNativePinLaunches: Set<UUID> = []
    var pendingSidebarPinOpenings: Set<UUID> = []
    var unresolvedSidebarPinOwners: [SurfaceID: UUID] = [:]
    var pendingProfileMoves: [UUID: BrowserProfileMove] = [:]
    var profileMoveCopiesToClose: Set<SurfaceID> = []
    var committingProfileMove = false
    private var sessions: [UUID: BrowserSurfaceSession] = [:]
    var pendingBrowserTabSelections: [SurfaceID: Bool] = [:]
    var pendingBrowserTabAddress: SurfaceID?
    var latestBrowserTabCreation: UUID?
    var pendingBrowserTabFocusGeneration: UInt64?
    private var processBindings: [UUID: (pid: pid_t, launch: Date?)] = [:]
    var surfaceTree = SurfaceTree()
    var usesSurfaceTree = false
    var mixedLayoutWorkspaces: Set<String> = []
    var placements: [SurfaceID: String] = [:]
    var standaloneBrowserViews: [SurfaceID: String] = [:]
    private var previewWindow: NSWindow?
    private let previewState = BrowserSidebarPreviewState()
    private lazy var refreshScheduler = CoalescedBrowserRefreshScheduler(isReady: { [weak self] in
        isWinMuxRuntimeReady || self?.previewWindow != nil
    }) { [weak self] in
        await self?.performScheduledRefresh()
    }
    private var browserFocusDeadline: Date?
    private var unresolvedNativeItems: Set<SurfaceID> = []
    private var unresolvedBrowserItems: Set<SurfaceID> = []
    var closedBrowserTabs: Set<SurfaceID> = []
    var restoredSelection: SurfaceID?
    var recentSelections: [SurfaceID] = []
    var selectedByWorkspace: [String: SurfaceID] = [:]
    private var restoredPlacements = false
    private var observedNativeMinimums: [SurfaceID: SurfaceMinimumSize] = [:]
    private var pendingNativeLayoutFocus: (id: SurfaceID, generation: UInt64, foregroundPID: Int32?)?

    func capturePlacementSnapshot() -> SurfaceWorkspaceSnapshot? {
        guard usesSurfaceTree else { return nil }
        syncSidebarPins()
        capturePinnedLayouts()
        reconcileSavedViews()
        let selected = restoredSelection ?? focusCoordinator.target
        var savedTree = surfaceTree
        for id in privateSurfaces { savedTree.remove(id) }
        for name in savedTree.roots.keys where Workspace.existing(byName: name)?.isIncognito == true { savedTree.removeWorkspace(name) }
        return .init(tree: savedTree, layoutWorkspaces: mixedLayoutWorkspaces.intersection(savedTree.roots.keys),
                     selected: selected.flatMap { savedTree.workspace(of: $0) == nil ? nil : $0 }, closedBrowserTabs: closedBrowserTabs,
                     browserPins: legacyBrowserPins, appPins: legacyAppPins, pinnedGroups: spacePinnedGroups,
                     pinShelves: pinShelves,
                     selectedByWorkspace: selectedByWorkspace.filter { savedTree.workspace(of: $0.value) == $0.key },
                     browserProfiles: browserProfiles, browserProfileBySpace: browserProfileBySpace,
                     savedViews: savedViews.filter { Workspace.existing(byName: $0.workspaceName)?.isIncognito != true })
    }

    func restorePlacementSnapshot(_ snapshot: SurfaceWorkspaceSnapshot) {
        guard (try? snapshot.validated()) != nil else { return }
        pendingNativeLayoutFocus = nil
        usesSurfaceTree = true
        surfaceTree = snapshot.tree
        mixedLayoutWorkspaces = snapshot.layoutWorkspaces
        closedBrowserTabs = snapshot.closedBrowserTabs
        restoreSavedPinState(snapshot)
        spacePinnedGroups = snapshot.pinnedGroups
        pinShelves = snapshot.pinShelves
        for desktop in savedViews {
            let workspace = Workspace.get(byName: desktop.workspaceName)
            workspace.assignProject(WorkspaceProjectId(desktop.spaceID))
            workspace.isPinnedGroup = desktop.isPinned; workspace.lifecycle = .durable
            workspace.retainsEmptyView = workspace.retainsEmptyView || desktop.retainsWhenEmpty
        }
        browserProfiles = snapshot.browserProfiles
        browserProfileBySpace = snapshot.browserProfileBySpace
        pendingNativePinLaunches = [:]
        failedNativePinLaunches = []
        restorePinnedGroups()
        pendingSidebarPinOpenings = []
        unresolvedSidebarPinOwners = [:]
        for pin in browserSidebarPins { _ = Workspace.get(byName: pin.workspaceName) }
        restoredSelection = snapshot.selected
        recentSelections = snapshot.selected.map { [$0] } ?? []
        selectedByWorkspace = snapshot.selectedByWorkspace
        restoredPlacements = true
        placements = [:]
        standaloneBrowserViews = [:]
        unresolvedNativeItems = []
        unresolvedBrowserItems = []
        for (workspace, nodes) in surfaceTree.roots {
            // Empty roots are bookkeeping left after moving/closing the last
            // surface; they must not recreate a named, permanent empty view.
            guard !nodes.flatMap(\.surfaces).isEmpty else { continue }
            Workspace.get(byName: workspace).hasContainedItems = true
            for id in nodes.flatMap(\.surfaces) {
                if case .browserTab = id {
                    placements[id] = workspace
                    if owner(of: id) == nil { unresolvedBrowserItems.insert(id) }
                } else if Window.get(bySurfaceID: id) == nil { unresolvedNativeItems.insert(id) }
            }
        }
        migrateSidebarPinsToSpaceGroups()
        // Inventory can arrive before native startup finishes reading its file.
        // Preserve such live tabs even if this snapshot predates them.
        for id in sessions.values.flatMap({ $0.inventory.tabs.keys }) where placements[id] == nil {
            if isPrivateSurface(id) {
                placements[id] = incognitoDestination(id, from: focus.workspace)
                continue
            }
            placements[id] = "Recovered"
            closedBrowserTabs.remove(id)
            Workspace.get(byName: "Recovered").hasContainedItems = true
        }
        for session in sessions.values where session.inventory.revision > 0 {
            reconcileRestoredBrowserPlacements(session.inventory)
        }
        reconcileSavedViews()
        scheduleRefresh()
    }

    /// Native discovery has exhausted its retries. Unclaimed IDs cannot regain
    /// an owner after this point, so do not checkpoint them into another restart.
    func finishNativeRestoration() {
        retireResolvedNativeReservations()
        let missing = unresolvedNativeItems
        unresolvedNativeItems = []
        for id in missing { surfaceTree.remove(id) }
        if let selected = restoredSelection, missing.contains(selected) { restoredSelection = nil }
        recentSelections.removeAll(where: missing.contains)
        if !missing.isEmpty { scheduleRefresh() }
    }

    /// A full inventory can retire saved references for profiles it actually
    /// owns. Other profiles may connect later and keep their saved placement.
    private func reconcileRestoredBrowserPlacements(_ inventory: BrowserInventory) {
        let profiles = Set(inventory.tabs.keys.compactMap { id -> UUID? in
            if case .browserTab(let profile, _) = id { return profile }
            return nil
        })
        let missing = unresolvedBrowserItems.filter { id in
            guard case .browserTab(let profile, _) = id else { return false }
            return profiles.contains(profile) && owner(of: id) == nil
        }
        for id in missing {
            browserPinDidClose(id)
            retireAbsentPinnedPage(id)
            if restoredSelection == id { restoredSelection = nil }
            recentSelections.removeAll { $0 == id }
        }
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

    public func connected(_ connection: UUID, processID: Int32, sendLayout: BrowserSurfaceSession.LayoutTransport? = nil, sendNewTab: BrowserSurfaceSession.NewTabTransport? = nil, sendHistory: BrowserSurfaceSession.HistoryTransport? = nil, send: @escaping BrowserSurfaceSession.Transport) {
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
        sessions[connection] = BrowserSurfaceSession(focusCoordinator: focusCoordinator, sendLayout: sendLayout, sendNewTab: sendNewTab, sendHistory: sendHistory,
            canRetryFocus: {
                BrowserToolbarController.shared.focusedControlSurfaceID == nil &&
                    !BrowserWindowDragController.shared.isDragging
            }, send: send)
        reconcileNativeHosts()
    }

    public func received(_ message: BrowserInventoryMessage, epoch: UUID, connection: UUID, protocolVersion: Int = 2) {
        guard let session = sessions[connection], protocolVersion >= 7 || !message.tabs.contains(where: \.privateBrowsing) else { return }
        if session.epoch == nil { session.connect(epoch: epoch) }
        session.supportsLayout = protocolVersion >= 3
        session.supportsBrowserControls = protocolVersion >= 4
        session.supportsToolbarActions = protocolVersion >= 9
        session.supportsHistory = protocolVersion >= 10
        session.supportsPrivacy = protocolVersion >= 8
        session.supportsTabCreation = protocolVersion >= 5
        session.supportsWorkspaceProfiles = protocolVersion >= 7
        let isInitialInventory = session.inventory.revision == 0
        let oldIDs = Set(session.inventory.tabs.keys)
        let closureFocus = captureClosureFocus()
        let closingWorkspace = closureFocus.selected.flatMap { workspaceName(for: $0) }.flatMap(Workspace.existing(byName:))
        guard session.reconcile(message, epoch: epoch) else { return }
        unresolvedBrowserItems.subtract(session.inventory.tabs.keys)
        let absentPinnedIDs = reconcileSidebarPinInventory(session.inventory, full: message.full, connection: connection)
        if message.full { reconcileRestoredBrowserPlacements(session.inventory) }
        if let target = focusCoordinator.target, session.inventory.tabs[target]?.hostMinimized == true {
            // A native titlebar or Dock action can minimize outside our toolbar.
            // Stale layout/focus replies must not reactivate that page.
            nativeSelectionChanged(nil)
        }
        let removedIDs = oldIDs.subtracting(session.inventory.tabs.keys).union(absentPinnedIDs).filter { owner(of: $0) == nil }
        for id in removedIDs {
            if privateSurfaces.contains(id) { retirePrivateSurface(id); continue }
            browserPinDidClose(id)
            closedBrowserTabs.insert(id)
            unresolvedBrowserItems.remove(id)
            placements.removeValue(forKey: id)
            standaloneBrowserViews.removeValue(forKey: id)
            surfaceTree.remove(id)
        }
        // A tab restored by Chromium (including explicit undo-close) is live.
        // Stale placement never reopens it; recover it as a new placement.
        // Only the first snapshot can contain unknown pages from restoration.
        // Later full snapshots also carry newly opened pages; place those in
        // the active group just like a delta, while keeping existing placements.
        let workspace = restoredPlacements && isInitialInventory && message.full ? "Recovered" : (previewWindow == nil ? regularWorkspaceForNewItem(regularArrivalWorkspace(focus.workspace)).name : "browser-alpha")
        let arrivalContext = focus.workspace
        let separateArrivals = config.newItemPlacement == .newView && previewWindow == nil &&
            !(restoredPlacements && isInitialInventory && message.full)
        for id in session.inventory.tabs.keys.sorted(by: { $0.description < $1.description }) {
            closedBrowserTabs.remove(id)
            if placements[id] == nil {
                let destination = session.inventory.tabs[id]?.privateBrowsing == true
                    ? incognitoDestination(id, from: arrivalContext)
                    : (separateArrivals ? standaloneBrowserDestination(id, in: regularArrivalWorkspace(arrivalContext)) : workspace)
                placements[id] = destination
                if isWinMuxRuntimeReady || isPrivateSurface(id) { _ = Workspace.get(byName: destination) }
                Workspace.existing(byName: destination)?.hasContainedItems = true
            }
        }
        reconcileSharedOrganization()
        let closedSelection = closureFocus.selected.map(removedIDs.contains) == true
        restoreFocusAfterClosing(removedIDs, snapshot: closureFocus, workspace: closingWorkspace)
        if usesSurfaceTree && !closedSelection && !holdsPendingBrowserFocus && BrowserToolbarController.shared.focusedControlSurfaceID == nil,
           processBindings[connection]?.pid == foregroundProcessID(),
           let focused = session.inventory.tabs.values.first(where: { $0.focused && !$0.hostMinimized }),
           !isProfileMoveArrival(focused.surfaceID, session: session),
           let workspaceName = placements[focused.surfaceID],
           let workspace = Workspace.existing(byName: workspaceName),
           workspace.isVisible || ((separateArrivals || focused.privateBrowsing) && !oldIDs.contains(focused.surfaceID)),
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
        migratePinnedDesktops()
        completePendingBrowserTabSelections()
        completePendingProfileMoves()
        pruneIncognitoSpaces()
        syncSidebarPins()
        scheduleRefresh()
    }

    public func disconnected(_ connection: UUID) {
        guard let session = sessions.removeValue(forKey: connection) else { return }
        unresolvedBrowserItems.formUnion(session.inventory.tabs.keys)
        for pin in browserSidebarPins {
            if let id = pin.surfaceID, session.inventory.tabs[id] != nil ||
                (pendingSidebarPinOpenings.contains(pin.id) && sessions.isEmpty) {
                unresolvedSidebarPinOwners[id] = connection
            }
        }
        let privateProfiles = Set(session.inventory.tabs.values.filter(\.privateBrowsing).compactMap { $0.surfaceID.browserProfileID })
        for id in privateSurfaces where owner(of: id) == nil &&
            (sessions.isEmpty || id.browserProfileID.map(privateProfiles.contains) == true) { retirePrivateSurface(id) }
        pruneIncognitoSpaces()
        if let epoch = session.epoch { session.disconnect(epoch: epoch) }
        for move in Array(pendingProfileMoves.values) where move.session === session { cancelProfileMove(move) }
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
        if let workspace = workspaceName(for: id) { selectedByWorkspace[workspace] = id }
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
            guard self.workspaceName(for: id) == workspace.name, self.isAvailable(id), !self.isProfileMoveCopy(id) else { return false }
            let browser = self.owner(of: id)?.inventory.tabs[id]
            // Automatic group activation picks a live tile. Restoring a Dock,
            // fullscreen or zoomed page remains an explicit sidebar selection.
            return browser?.hostMinimized != true && browser?.hostFullscreen != true && browser?.hostZoomed != true
        }
        if let recent = recentSelections.first(where: belongs) { return recent }
        if let saved = selectedByWorkspace[workspace.name], belongs(saved) { return saved }
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

    func tabCreationSession(profileID: UUID? = nil, sourceSurfaceID: SurfaceID? = nil) -> BrowserSurfaceSession? {
        if let id = sourceSurfaceID ?? focusCoordinator.target, let owner = owner(of: id), owner.supportsTabCreation,
           profileID == nil || owner.inventory.tabs.keys.contains(where: { $0.browserProfileID == profileID }) { return owner }
        let capable = sessions.values.filter { $0.supportsTabCreation && $0.epoch != nil }
        if let profileID {
            let matching = capable.filter { $0.inventory.tabs.keys.contains { $0.browserProfileID == profileID } }
            if matching.count == 1 { return matching[0] }
            if !matching.isEmpty { return nil }
        }
        return capable.count == 1 ? capable[0] : nil
    }

    var supportsWorkspaceProfiles: Bool {
        tabCreationSession()?.supportsWorkspaceProfiles == true
    }

    func placeCreatedBrowserTab(_ id: SurfaceID, in workspaceName: String, focusAddress: Bool, selectCreated: Bool, focusGeneration: UInt64,
                                after source: SurfaceID? = nil) {
        placements[id] = workspaceName
        closedBrowserTabs.remove(id)
        if isWinMuxRuntimeReady { _ = Workspace.get(byName: workspaceName) }
        if usesSurfaceTree {
            mixedLayoutWorkspaces.insert(workspaceName)
            if surfaceTree.workspace(of: id) == nil {
                surfaceTree.reconcile([id] + (surfaceTree.roots[workspaceName] ?? []).flatMap(\.surfaces), in: workspaceName)
            }
            _ = surfaceTree.moveToRoot(id, in: workspaceName, after: source)
        }
        if selectCreated {
            pendingBrowserTabSelections = [id: focusAddress]
            pendingBrowserTabFocusGeneration = focusGeneration
            completePendingBrowserTabSelections()
        }
        scheduleRefresh()
    }

    /// Inventory and creation replies can arrive in either order. Reserve by
    /// durable page identity, and retain the request's captured Space/display.
    func standaloneBrowserDestination(_ id: SurfaceID, in context: Workspace) -> String {
        if let name = standaloneBrowserViews[id], let existing = Workspace.existing(byName: name),
           existing.projectId == context.projectId,
           MonitorViewportId(existing.workspaceMonitor) == MonitorViewportId(context.workspaceMonitor) {
            positionStandaloneWorkspace(existing, after: context)
            return name
        }
        let destination = newStandaloneWorkspace(in: context,
            reserved: Set(placements.values).union(standaloneBrowserViews.values))
        standaloneBrowserViews[id] = destination.name
        return destination.name
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
        let selected = workspaceSidebarSelectedSurfaces(in: surfaceTree)
        return sessions.values.flatMap { $0.inventory.tabs.values }
            .filter { placements[$0.surfaceID] == workspace && owner(of: $0.surfaceID) != nil }
            .sorted { $0.surfaceID.description < $1.surfaceID.description }
            .map { record in .init(kind: .browserTab(.init(
                surfaceID: record.surfaceID, workspaceName: workspace,
                title: record.title.isEmpty ? "New tab" : record.title,
                isFocused: focusCoordinator.target == record.surfaceID, iconPNGBase64: record.iconPNGBase64,
                isSelected: selected.contains(record.surfaceID), isLoading: record.isLoading))) }
    }

    func sidebarProjection() -> BrowserSidebarProjection {
        let selected = workspaceSidebarSelectedSurfaces(in: surfaceTree)
        var result = BrowserSidebarProjection()
        var ownerCounts: [SurfaceID: Int] = [:]
        for session in sessions.values {
            for id in session.inventory.tabs.keys { ownerCounts[id, default: 0] += 1 }
        }
        for (connection, session) in sessions {
            let appPath: String?
            if let binding = processBindings[connection],
               let app = NSRunningApplication(processIdentifier: binding.pid), !app.isTerminated,
               app.launchDate == binding.launch { appPath = app.bundleURL?.path }
            else { appPath = nil }
            for record in session.inventory.tabs.values where ownerCounts[record.surfaceID] == 1 {
                guard let workspace = placements[record.surfaceID] else { continue }
                result.rowsByWorkspace[workspace, default: []].append(.init(kind: .browserTab(.init(
                    surfaceID: record.surfaceID, workspaceName: workspace,
                    title: record.title.isEmpty ? "New tab" : record.title,
                    isFocused: focusCoordinator.target == record.surfaceID, iconPNGBase64: record.iconPNGBase64,
                    isSelected: selected.contains(record.surfaceID), isLoading: record.isLoading))))
                result.appPaths[record.surfaceID] = appPath
            }
        }
        for name in Array(result.rowsByWorkspace.keys) {
            result.rowsByWorkspace[name]?.sort { $0.id < $1.id }
        }
        result.selectedSurfaces = selected
        return result
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
        unresolvedBrowserItems.remove(id)
        placements.removeValue(forKey: id)
        surfaceTree.remove(id)
        unresolvedSidebarPinOwners.removeValue(forKey: id)
    }

    /// Reconcile owner membership before layout or presentation, including when
    /// the sidebar is disabled. This pass uses identities only; title/icon reads
    /// cannot determine membership or import an out-of-date native arrangement.
    func reconcileSharedOrganization() {
        guard usesSurfaceTree else { return }
        retireResolvedNativeReservations()
        let browserByWorkspace = Dictionary(grouping: placements.keys, by: { placements[$0]! })
        let workspaces = Dictionary(uniqueKeysWithValues: Workspace.all.map { ($0.name, $0) })
        let names = Set(workspaces.keys).union(surfaceTree.roots.keys).union(browserByWorkspace.keys)
        let knownSurfaces = Set(surfaceTree.roots.values.flatMap { $0.flatMap(\.surfaces) })
        for name in names.sorted() {
            let root = workspaces[name]?.existingRootTilingContainer
            let native = root?.allLeafWindowsRecursive.filter(participatesInSharedTiling) ?? []
            let nativeIDs = native.map(\.surfaceID)
            let browserIDs = (browserByWorkspace[name] ?? []).filter { owner(of: $0) != nil }
                .sorted { $0.description < $1.description }
            let temporaryNative = Set((surfaceTree.roots[name] ?? []).flatMap(\.surfaces).filter {
                guard let window = Window.get(bySurfaceID: $0), window.nodeWorkspace?.name == name else { return false }
                return !window.isFloating && !participatesInSharedTiling(window)
            })
            let shouldImportNative = surfaceTree.roots[name] == nil
            if shouldImportNative && nativeIDs.isEmpty && browserIDs.isEmpty { continue }
            surfaceTree.reconcile(nativeIDs + browserIDs, in: name,
                retaining: Set(browserByWorkspace[name] ?? []).union(unresolvedNativeItems).union(temporaryNative))
            if shouldImportNative, let root {
                importNativeOrganization(root, available: Set(nativeIDs), in: name)
                if let selected = focusCoordinator.target ?? focus.windowOrNil?.surfaceID { surfaceTree.select(selected) }
            } else if let root, !Set(nativeIDs).isSubset(of: knownSurfaces) {
                // Discovery may finish after browser inventory. Adopt only whole
                // newly discovered native subtrees; existing mixed groups win.
                let native = nativeOrganization(root, available: Set(nativeIDs))
                let arrivals = native.nodes.filter { Set($0.surfaces).isDisjoint(with: knownSurfaces) }
                _ = surfaceTree.importOrganization(arrivals, in: name, layouts: native.layouts,
                    activeSurfaces: native.active, weights: native.weights)
            }
        }
        syncSidebarPins()
        migratePinnedDesktops()
        reconcileSavedViews()
    }

    /// Project the current organization without changing it. Stale native rows
    /// can be dropped after an asynchronous title read, but cannot move owners.
    func organizedRows(native: [WorkspaceSidebarItemViewModel], in workspace: String,
                       projection: BrowserSidebarProjection? = nil) -> [WorkspaceSidebarItemViewModel] {
        let browserRows = projection.map { $0.rowsByWorkspace[workspace] ?? [] } ?? rows(in: workspace)
        guard usesSurfaceTree else { return native + browserRows }
        var available: [SurfaceID: WorkspaceSidebarItemViewModel] = [:]
        var nativeOnlyRows: [WorkspaceSidebarItemViewModel] = []
        func collect(_ item: WorkspaceSidebarItemViewModel) {
            switch item.kind {
            case .window(let window):
                guard let owner = Window.get(bySurfaceID: window.surfaceID),
                      owner.nodeWorkspace?.name == workspace else { return }
                if !participatesInSharedTiling(owner) {
                    nativeOnlyRows.append(item)
                    return
                }
                available[window.surfaceID] = .init(kind: .surface(.init(surfaceID: window.surfaceID,
                    title: window.title ?? window.appName, appName: window.appName, isFocused: window.isFocused,
                    appBundleId: window.appBundleId, appBundlePath: window.appBundlePath)))
            case .browserTab(let tab):
                let path = projection != nil ? projection?.appPaths[tab.surfaceID]
                    : browserProcess(for: tab.surfaceID).flatMap { NSRunningApplication(processIdentifier: $0)?.bundleURL?.path }
                available[tab.surfaceID] = .init(kind: .surface(.init(surfaceID: tab.surfaceID,
                    title: tab.title, appName: "WinMux Browser", isFocused: tab.isFocused,
                    appBundleId: "com.jameslyons.winmux.browser.alpha", appBundlePath: path, iconPNGBase64: tab.iconPNGBase64,
                    isSelected: tab.isSelected, isLoading: tab.isLoading)))
            case .tabGroup(let group):
                group.tabs.forEach { collect(.init(kind: .window($0))) }
            case .surface, .surfaceGroup, .pinnedBrowserTab: break
            }
        }
        (native + browserRows).forEach(collect)
        let selected = projection?.selectedSurfaces ?? workspaceSidebarSelectedSurfaces(in: surfaceTree)
        func project(_ node: SurfaceTreeNode) -> [WorkspaceSidebarItemViewModel] {
            switch node {
            case .surface(let id):
                if let row = available[id], case .surface(var surface) = row.kind {
                    surface.isSelected = selected.contains(id)
                    return [.init(kind: .surface(surface))]
                }
                return []
            case .group(let id, let children):
                let visible = children.flatMap(project)
                guard !visible.isEmpty else { return [] }
                // Split containers arrange panes; only stacks add a header.
                return (surfaceTree.layouts[id] ?? .stack) == .stack ? [.init(kind: .surfaceGroup(id, visible))] : visible
            }
        }
        return (surfaceTree.roots[workspace] ?? []).flatMap(project) + nativeOnlyRows
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
    func moveGroup(_ id: UUID, to destination: Workspace, following selected: SurfaceID? = nil, atStart: Bool = false,
                   edit: @escaping (inout SurfaceTree) -> Bool = { _ in true }) -> Bool {
        guard !destination.isArchived, canMoveGroup(id), let group = surfaceTree.group(id),
              let sourceName = surfaceTree.workspace(ofGroup: id), sourceName != destination.name,
              let source = Workspace.existing(byName: sourceName) else { return false }
        guard selected.map(group.surfaces.contains) ?? true else { return false }
        let focusGeneration = focusCoordinator.generation
        if let accepted = moveUsingDestinationProfile(group.surfaces, to: destination, commit: { [weak self] in
            guard let self, self.surfaceTree.group(id) == group else { return false }
            return self.moveGroup(id, to: destination,
                following: self.focusCoordinator.generation == focusGeneration ? selected : nil, atStart: atStart, edit: edit)
        }) { return accepted }
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
        guard let change = candidate.preparingOrganizationChange(in: affected, reserving: reservations,
            selected: focusCoordinator.target, { $0.moveGroupToRoot(id, in: destination.name, atStart: atStart) && edit(&$0) }) else { return false }
        let members = Set(group.surfaces)
        let movedSelection = (focusCoordinator.target ?? focus.windowOrNil?.surfaceID).map(members.contains) == true
        guard commitOrganizationChange(change) else { return false }
        restoredSelection = nil
        if let selected { _ = select(selected) }
        else if movedSelection { retainSourceSelection(in: source) }
        scheduleRefresh()
        return true
    }

    func retainSourceSelection(in source: Workspace) {
        let remaining = (surfaceTree.roots[source.name] ?? []).flatMap(\.surfaces)
            .first { isAvailable($0) && !isProfileMoveCopy($0) }
        if remaining.map({ select($0) == .issued }) != true {
            _ = source.focusWorkspace()
            nativeSelectionChanged(nil)
        }
    }

    /// Shared organization dispatches owner layout only after capability checks.
    /// Native owners are revalidated; browser profile identity is preserved.
    func organize(_ id: SurfaceID, before target: SurfaceID? = nil, earlier: Bool? = nil, groupWithSelection: Bool = false, layout: SurfaceContainerLayout = .stack) {
        guard usesSurfaceTree, isAvailable(id) else { return }
        if let target {
            guard isAvailable(target), let name = workspaceName(for: target),
                  let destination = Workspace.existing(byName: name) else { return }
            let source = workspaceName(for: id).flatMap(Workspace.existing(byName:))
            if source !== destination, moveUsingDestinationProfile([id], to: destination, commit: { [weak self] in
                guard let self, self.isAvailable(target), self.workspaceName(for: target) == name else { return false }
                self.organize(id, before: target)
                return self.workspaceName(for: id) == name
            }) != nil { return }
            let movedSelection = focusCoordinator.target == id
            if editOrganization(of: id, movingTo: destination, { $0.move(id, before: target) }),
               let source, source !== destination, movedSelection { retainSourceSelection(in: source) }
        } else if let earlier { _ = editOrganization(of: id) { $0.reorder(id, earlier: earlier) } }
        else if groupWithSelection, let target = focusCoordinator.target, isAvailable(target) {
            _ = combineViews(id, with: target, layout: layout)
        }
        scheduleRefresh()
    }

    func ungroup(_ id: UUID) {
        guard let member = surfaceTree.group(id)?.surfaces.first(where: isAvailable),
              editOrganization(of: member, { $0.ungroup(id) }) else { return }
        removePinnedView(id)
    }

    /// Structural commands must never edit the old native tree behind a browser
    /// selection. Validate the owners and candidate snapshot before committing.
    func editOrganization(of id: SurfaceID, _ edit: (inout SurfaceTree) -> Bool) -> Bool {
        guard usesSurfaceTree, isAvailable(id), let workspace = surfaceTree.workspace(of: id),
              let reservations = organizationReservations(in: [workspace]) else { return false }
        guard let change = surfaceTree.preparingOrganizationChange(in: [workspace], reserving: reservations,
            selected: focusCoordinator.target, edit) else { return false }
        return commitOrganizationChange(change)
    }

    /// Commit a prepared edit spanning complete panes. Browser transfers across
    /// Spaces must enter the profile transaction path, never this synchronous
    /// organization boundary. Native owners can move between either Space.
    func editOrganization(in workspaces: Set<String>, selecting selection: SurfaceID? = nil,
                          admittingFloating: Set<SurfaceID> = [], floating: Set<SurfaceID> = [],
                          _ edit: (inout SurfaceTree) -> Bool) -> Bool {
        guard usesSurfaceTree, let reservations = organizationReservations(in: workspaces) else { return false }
        var baseline = surfaceTree
        for id in admittingFloating.sorted(by: { $0.description < $1.description }) {
            guard let window = Window.get(bySurfaceID: id), window.isFloating, window.toLiveFocusOrNil() != nil,
                  let source = window.nodeWorkspace?.name, workspaces.contains(source), baseline.workspace(of: id) == nil else { return false }
            baseline.reconcile((baseline.roots[source] ?? []).flatMap(\.surfaces) + [id], in: source)
        }
        guard let change = baseline.preparingOrganizationChange(in: workspaces, reserving: reservations,
                  selected: selection ?? focusCoordinator.target, edit) else { return false }
        for effect in change.membership where effect.surfaceID.browserProfileID != nil {
            guard Workspace.existing(byName: effect.source)?.projectId == Workspace.existing(byName: effect.destination)?.projectId else { return false }
        }
        let movedSelection = change.membership.first { $0.surfaceID == (focusCoordinator.target ?? focus.windowOrNil?.surfaceID) }
        guard commitOrganizationChange(change, admittingFloating: admittingFloating, floating: floating) else { return false }
        if let source = movedSelection.flatMap({ Workspace.existing(byName: $0.source) }) { retainSourceSelection(in: source) }
        return true
    }

    /// Prepare the entire cross-workspace edit before changing owner membership.
    /// This synchronous commit has no suspension between validation and binding.
    func editOrganization(of id: SurfaceID, movingTo destination: Workspace,
                          _ edit: @escaping (inout SurfaceTree) -> Bool) -> Bool {
        guard usesSurfaceTree, !destination.isArchived, isAvailable(id), let source = surfaceTree.workspace(of: id),
              workspaceName(for: id) == source else { return false }
        if source == destination.name { return editOrganization(of: id, edit) }
        if let accepted = moveUsingDestinationProfile([id], to: destination, commit: { [weak self] in
            self?.editOrganization(of: id, movingTo: destination, edit) ?? false
        }) { return accepted }
        let affected = Set([source, destination.name])
        guard let reservations = organizationReservations(in: affected) else { return false }
        guard let change = surfaceTree.preparingOrganizationChange(in: affected, reserving: reservations,
            selected: focusCoordinator.target, { $0.moveToRoot(id, in: destination.name) && edit(&$0) }) else { return false }
        return commitOrganizationChange(change)
    }

    /// The model has decided membership and layout. Revalidate every affected
    /// owner before executing any binding change, with no suspension mid-commit.
    private func commitOrganizationChange(_ change: SurfaceOrganizationChange,
        admittingFloating: Set<SurfaceID> = [], floating: Set<SurfaceID> = []
    ) -> Bool {
        var nativeMoves: [(Window, Workspace)] = []
        var nativeFloats: [(Window, Workspace)] = []
        for id in admittingFloating.union(floating) {
            guard let window = Window.get(bySurfaceID: id), window.toLiveFocusOrNil() != nil,
                  let name = change.tree.workspace(of: id), change.workspaces.contains(name),
                  let destination = Workspace.existing(byName: name), !destination.isArchived,
                  canPlaceSurface(id, in: destination), participatesInSharedTiling(window) || window.isFloating else { return false }
            if admittingFloating.contains(id), !window.isFloating { return false }
            if floating.contains(id) { nativeFloats.append((window, destination)) }
            else { nativeMoves.append((window, destination)) }
        }
        for effect in change.membership {
            guard workspaceName(for: effect.surfaceID) == effect.source,
                  let destination = Workspace.existing(byName: effect.destination), !destination.isArchived,
                  canPlaceSurface(effect.surfaceID, in: destination) else { return false }
            switch effect.surfaceID {
            case .browserTab:
                guard owner(of: effect.surfaceID)?.supportsLayout == true else { return false }
            case .nativeWindow:
                guard let window = Window.get(bySurfaceID: effect.surfaceID),
                      window.toLiveFocusOrNil() != nil, participatesInSharedTiling(window) || admittingFloating.contains(effect.surfaceID) else { return false }
                if !floating.contains(effect.surfaceID), !admittingFloating.contains(effect.surfaceID) { nativeMoves.append((window, destination)) }
            }
        }
        if !nativeMoves.isEmpty || !nativeFloats.isEmpty {
            syncClosedWindowsCacheToCurrentWorld()
            suppressPostDragAxObserverEvents(for: (nativeMoves + nativeFloats).map { $0.0.windowId })
            for (window, destination) in nativeMoves {
                let binding = workspaceAppendBindingData(targetWorkspace: destination, index: INDEX_BIND_LAST)
                window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
            }
            for (window, destination) in nativeFloats { window.bindAsFloatingWindow(to: destination) }
        }
        for effect in change.membership {
            if case .browserTab = effect.surfaceID { placements[effect.surfaceID] = effect.destination }
        }
        surfaceTree = change.tree
        for id in floating { surfaceTree.remove(id) }
        mixedLayoutWorkspaces.formUnion(change.workspaces)
        scheduleRefresh()
        return true
    }

    /// A restored native identity may still be waiting for its real app. It is
    /// a temporary reservation, not an owner that can veto unrelated live edits.
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

    /// Commit replacements only after the whole move passed preflight. Originals
    /// remain in their source until Chromium confirms their ordinary close.
    func installProfileMoveReplacements(_ move: BrowserProfileMove) {
        let selected = focusCoordinator.target
        for (old, new) in move.replacements {
            replaceSavedBinding(old, with: new)
            let destination = placements[old] ?? move.destination.name
            surfaceTree.remove(new)
            if !surfaceTree.replaceSurface(old, with: new) {
                surfaceTree.reconcile((surfaceTree.roots[destination] ?? []).flatMap(\.surfaces) + [new], in: destination)
            }
            placements[new] = destination
            standaloneBrowserViews.removeValue(forKey: new)
            if let source = move.sources[old] {
                placements[old] = source
                surfaceTree.reconcile((surfaceTree.roots[source] ?? []).flatMap(\.surfaces) + [old], in: source)
            }
            for index in browserSidebarPins.indices where browserSidebarPins[index].surfaceID == old {
                let pin = browserSidebarPins[index]
                browserSidebarPins[index] = .init(id: pin.id, profileID: new.browserProfileID!,
                    workspaceName: destination, title: pin.title, url: pin.url,
                    surfaceID: new, iconPNGBase64: pin.iconPNGBase64)
            }
            for name in selectedByWorkspace.keys where selectedByWorkspace[name] == old && name == destination {
                selectedByWorkspace[name] = new
            }
            recentSelections = recentSelections.map { $0 == old ? new : $0 }
            if restoredSelection == old { restoredSelection = new }
        }
        if let pin = move.closedPin, let new = move.closedPinReplacement,
           let index = browserSidebarPins.firstIndex(where: { $0.id == pin.id }) {
            browserSidebarPins[index] = .init(id: pin.id, profileID: new.browserProfileID!,
                workspaceName: move.destination.name, title: pin.title, url: pin.url,
                surfaceID: new, iconPNGBase64: pin.iconPNGBase64)
            placeCreatedBrowserTab(new, in: move.destination.name, focusAddress: false,
                selectCreated: false, focusGeneration: focusCoordinator.generation)
        }
        if let selected, let replacement = move.replacements[selected] { _ = select(replacement) }
        for old in move.replacements.keys { _ = close(old) }
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
        // Selecting or restoring an existing pin must not flatten its group.
        if workspaceName(for: id) == workspace, surfaceTree.workspace(of: id) == workspace { return true }
        if case .browserTab = id {
            if let old = placements[id] { mixedLayoutWorkspaces.insert(old) }
            mixedLayoutWorkspaces.insert(workspace)
            placements[id] = workspace
            if surfaceTree.workspace(of: id) == nil {
                surfaceTree.reconcile((surfaceTree.roots[workspace] ?? []).flatMap(\.surfaces) + [id], in: workspace)
            }
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

    func applyPinnedTemplate(_ layout: [PinnedLayoutNode], bindings: [UUID: SurfaceID], workspace: String) {
        surfaceTree.restorePinnedLayout(layout, bindings: bindings, in: workspace)
        mixedLayoutWorkspaces.insert(workspace)
    }

    func migratePinnedNodes(_ nodes: [SurfaceTreeNode], from source: String, to destination: String) {
        for node in nodes {
            switch node {
            case .group(let id, _): _ = surfaceTree.moveGroupToRoot(id, in: destination)
            case .surface(let id): _ = surfaceTree.moveToRoot(id, in: destination)
            }
            for id in node.surfaces {
                if case .browserTab = id { placements[id] = destination }
                else if let window = Window.get(bySurfaceID: id) {
                    let target = Workspace.get(byName: destination)
                    let binding = workspaceAppendBindingData(targetWorkspace: target, index: INDEX_BIND_LAST)
                    window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
                }
            }
        }
        mixedLayoutWorkspaces.formUnion([source, destination])
        if let selected = restoredSelection, nodes.flatMap(\.surfaces).contains(selected), focus.workspace.name == source {
            _ = Workspace.get(byName: destination).focusWorkspace(restoringSurfaceSelection: false)
        }
    }

    func transferPinnedWorkspace(_ source: Workspace, to destination: Workspace) -> Bool {
        let nodes = surfaceTree.roots[source.name] ?? []
        let pending = Set(browserSidebarPins.filter { pendingSidebarPinOpenings.contains($0.id) }.compactMap(\.surfaceID))
        guard !destination.isArchived, nodes.flatMap(\.surfaces).allSatisfy({ canMoveSurface($0) || pending.contains($0) }),
              source.allLeafWindowsRecursive.allSatisfy(canAdoptNativePinWindow) else { return false }
        // All owners are checked before any native binding or tree edit.
        migratePinnedNodes(nodes, from: source.name, to: destination.name)
        for window in source.allLeafWindowsRecursive {
            let binding = workspaceAppendBindingData(targetWorkspace: destination, index: INDEX_BIND_LAST)
            window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
        }
        return true
    }

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
        usesSurfaceTree && (pendingProfileMoves.values.contains(where: { $0.destination.name == workspace }) ||
            browserSidebarPins.contains(where: { $0.workspaceName == workspace }) || placements.values.contains(workspace) ||
            (surfaceTree.roots[workspace] ?? []).flatMap(\.surfaces).contains(where: unresolvedNativeItems.contains))
    }

    func containsVisibleBrowserItems(in workspace: String) -> Bool {
        usesSurfaceTree && (browserSidebarPins.contains(where: { $0.workspaceName == workspace }) ||
            placements.contains { $0.value == workspace && owner(of: $0.key) != nil })
    }

    func moveWorkspaceContents(from source: String, to target: String) {
        guard source != target, Workspace.existing(byName: source)?.isIncognito == Workspace.existing(byName: target)?.isIncognito else { return }
        if Workspace.existing(byName: source)?.isIncognito == true,
           Workspace.existing(byName: source)?.projectId != Workspace.existing(byName: target)?.projectId { return }
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
    /// The saved tree keeps native reservations until discovery finishes.
    func liveLayoutTree(in workspace: Workspace) -> SurfaceTree {
        retireResolvedNativeReservations()
        var excluded: Set<SurfaceID> = []
        for id in (surfaceTree.roots[workspace.name] ?? []).flatMap(\.surfaces) {
            // Keep temporary native absence in the saved tree, but never place
            // floating, minimized, fullscreen or unresolved windows as tiles.
            let browser = owner(of: id)?.inventory.tabs[id]
            if browser?.hostMinimized == true || browser?.hostFullscreen == true || browser?.hostZoomed == true ||
                unresolvedNativeItems.contains(id) || Window.get(bySurfaceID: id).map({ !participatesInSharedTiling($0) }) == true {
                excluded.insert(id)
            }
        }
        return surfaceTree.projecting(in: workspace.name, excluding: excluded)
    }

    func plannedSurfaces(in workspace: Workspace) -> [SurfacePlacement] {
        plannedLayout(in: workspace).surfaces
    }

    func stackChrome(in workspace: Workspace) -> SurfaceStackChrome {
        guard usesSurfaceTree, hasMixedLayout(in: workspace), config.windowTabs.enabled else { return .init() }
        return .init(headerHeight: Int(resolvedWindowTabBarHeight()), sideInset: Int(windowTabGroupShellHorizontalInset()),
                     bottomInset: Int(windowTabGroupShellBottomInset()))
    }

    func plannedLayout(in workspace: Workspace) -> SurfaceLayoutPlan {
        let livePlan = liveLayoutTree(in: workspace)
        let rect = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        return livePlan.layout(in: workspace.name, frame: .init(x: Int(rect.topLeftX.rounded()),
            y: Int(rect.topLeftY.rounded()), width: Int(rect.width.rounded()), height: Int(rect.height.rounded())),
            visible: workspace.isVisible && !hasNativeFullscreenLayout(in: workspace), minimumSizes: minimumSizes(in: workspace),
            selectedSurface: rootPresentation(in: workspace) == .selectedRoot
                ? (focusCoordinator.target.flatMap { livePlan.workspace(of: $0) == workspace.name ? $0 : nil } ?? preferredSurface(in: workspace))
                : focusCoordinator.target,
            recentSelections: recentSelections, rootPresentation: rootPresentation(in: workspace), stackChrome: stackChrome(in: workspace))
    }

    func rootPresentation(in workspace: Workspace) -> SurfaceRootPresentation {
        workspace.isPinnedGroup ? .selectedRoot : .adaptiveTiles
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
        if previewWindow != nil {
            reconcileSharedOrganization()
            refreshPreview()
        }
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
            reconcileSharedOrganization()
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
        reconcileSharedOrganization()
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
        snapshot.configuration.visibility = .expanded
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
