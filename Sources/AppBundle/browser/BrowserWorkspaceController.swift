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
    private var sessions: [UUID: BrowserSurfaceSession] = [:]
    private var processBindings: [UUID: (pid: pid_t, launch: Date?)] = [:]
    private(set) var surfaceTree = SurfaceTree()
    var usesSurfaceTree = false
    private var mixedLayoutWorkspaces: Set<String> = []
    private var placements: [SurfaceID: String] = [:]
    private var previewWindow: NSWindow?
    private let previewState = BrowserSidebarPreviewState()
    private var refreshPending = false
    private var browserFocusDeadline: Date?
    private var unresolvedNativeItems: Set<SurfaceID> = []
    private var closedBrowserTabs: Set<SurfaceID> = []
    private var restoredSelection: SurfaceID?
    private var restoredPlacements = false

    func capturePlacementSnapshot() -> SurfaceWorkspaceSnapshot? {
        guard usesSurfaceTree else { return nil }
        let selected = restoredSelection ?? focusCoordinator.target
        return .init(tree: surfaceTree, layoutWorkspaces: mixedLayoutWorkspaces.intersection(surfaceTree.roots.keys),
                     selected: selected.flatMap { surfaceTree.workspace(of: $0) == nil ? nil : $0 }, closedBrowserTabs: closedBrowserTabs)
    }

    func restorePlacementSnapshot(_ snapshot: SurfaceWorkspaceSnapshot) {
        guard (try? snapshot.validated()) != nil else { return }
        usesSurfaceTree = true
        surfaceTree = snapshot.tree
        mixedLayoutWorkspaces = snapshot.layoutWorkspaces
        closedBrowserTabs = snapshot.closedBrowserTabs
        restoredSelection = snapshot.selected
        restoredPlacements = true
        placements = [:]
        unresolvedNativeItems = []
        for (workspace, nodes) in surfaceTree.roots {
            _ = Workspace.get(byName: workspace)
            for id in nodes.flatMap(\.surfaces) {
                if case .browserTab = id { placements[id] = workspace }
                else { unresolvedNativeItems.insert(id) }
            }
        }
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

    public func connected(_ connection: UUID, processID: Int32, sendLayout: BrowserSurfaceSession.LayoutTransport? = nil, send: @escaping BrowserSurfaceSession.Transport) {
        processBindings = processBindings.filter { _, binding in
            binding.pid != processID && NSRunningApplication(processIdentifier: binding.pid)?.isTerminated == false
        }
        processBindings[connection] = (processID, NSRunningApplication(processIdentifier: processID)?.launchDate)
        sessions[connection] = BrowserSurfaceSession(focusCoordinator: focusCoordinator, sendLayout: sendLayout, send: send)
        reconcileNativeHosts()
    }

    public func received(_ message: BrowserInventoryMessage, epoch: UUID, connection: UUID, protocolVersion: Int = 2) {
        guard let session = sessions[connection] else { return }
        if session.epoch == nil { session.connect(epoch: epoch) }
        session.supportsLayout = protocolVersion >= 3
        let oldIDs = Set(session.inventory.tabs.keys)
        guard session.reconcile(message, epoch: epoch) else { return }
        for id in oldIDs.subtracting(session.inventory.tabs.keys) where owner(of: id) == nil {
            closedBrowserTabs.insert(id)
            placements.removeValue(forKey: id)
            surfaceTree.remove(id)
        }
        // A tab restored by Chromium (including explicit undo-close) is live.
        // Stale placement never reopens it; recover it as a new placement.
        let workspace = restoredPlacements && message.full ? "Recovered" : (previewWindow == nil ? focus.workspace.name : "browser-alpha")
        for id in session.inventory.tabs.keys {
            closedBrowserTabs.remove(id)
            if placements[id] == nil {
                placements[id] = workspace
                if isWinMuxRuntimeReady { _ = Workspace.get(byName: workspace) }
            }
        }
        scheduleRefresh()
    }

    public func disconnected(_ connection: UUID) {
        guard let session = sessions.removeValue(forKey: connection) else { return }
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
        if isWinMuxRuntimeReady { restoredSelection = nil }
        if let id { surfaceTree.select(id) }
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

    private func fenceBrowsers(generation: UInt64, target: SurfaceID?) {
        for session in sessions.values {
            // The fence is revision/target independent on the owner; an empty
            // workspace still cancels the old tab focus without inventing an ID.
            guard let wireID = target ?? session.inventory.tabs.keys.first else { continue }
            session.supersedeFocus(generation: generation, target: wireID) { [weak self] outcome in
                guard outcome == .issued, let self, let target,
                      self.focusCoordinator.isCurrent(generation, target: target) else { return }
                _ = NativeWindowSurfaceAdapter(surfaceID: target).requestFocus()
            }
        }
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
    func select(_ id: SurfaceID) -> SurfaceActionOutcome {
        restoredSelection = nil
        if isAvailable(id) { surfaceTree.select(id) }
        switch id {
            case .browserTab:
                guard let session = owner(of: id) else { return .unavailable }
                if let name = placements[id], let workspace = Workspace.existing(byName: name), workspace !== focus.workspace {
                    _ = workspace.focusWorkspace()
                }
                let result = BrowserTabSurfaceAdapter(surfaceID: id, session: session).requestFocus()
                if result == .issued {
                    browserFocusDeadline = Date().addingTimeInterval(1)
                    let generation = focusCoordinator.generation
                    for other in sessions.values where other !== session {
                        other.supersedeFocus(generation: generation, target: id) { [weak self, weak session] outcome in
                            guard outcome == .issued, let self, let session,
                                  self.focusCoordinator.target == id, self.owner(of: id) === session else { return }
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
                guard Window.get(bySurfaceID: id)?.toLiveFocusOrNil() != nil else { return .unavailable }
                guard let generation = focusCoordinator.select(id) else { return .unavailable }
                let result = NativeWindowSurfaceAdapter(surfaceID: id).requestFocus()
                fenceBrowsers(generation: generation, target: id)
                scheduleRefresh()
                return result
        }
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

    func organizedRows(native: [WorkspaceSidebarItemViewModel], in workspace: String) -> [WorkspaceSidebarItemViewModel] {
        guard usesSurfaceTree else { return native + rows(in: workspace) }
        var available: [SurfaceID: WorkspaceSidebarItemViewModel] = [:]
        var ordered: [SurfaceID] = []
        let importNativeGroups = surfaceTree.roots[workspace] == nil
        var nativeGroups: [[SurfaceID]] = []
        func collect(_ item: WorkspaceSidebarItemViewModel) {
            switch item.kind {
            case .window(let window):
                ordered.append(window.surfaceID)
                available[window.surfaceID] = .init(kind: .surface(.init(surfaceID: window.surfaceID,
                    title: window.title ?? window.appName, appName: window.appName, isFocused: window.isFocused)))
            case .browserTab(let tab):
                ordered.append(tab.surfaceID)
                available[tab.surfaceID] = .init(kind: .surface(.init(surfaceID: tab.surfaceID,
                    title: tab.title, appName: "WinMux Browser", isFocused: tab.isFocused)))
            case .tabGroup(let group):
                nativeGroups.append(group.tabs.map(\.surfaceID))
                group.tabs.forEach { collect(.init(kind: .window($0))) }
            case .surface, .surfaceGroup: break
            }
        }
        (native + rows(in: workspace)).forEach(collect)
        unresolvedNativeItems.subtract(available.keys)
        surfaceTree.reconcile(ordered, in: workspace,
                              retaining: Set(placements.filter { $0.value == workspace }.map(\.key)).union(unresolvedNativeItems))
        if importNativeGroups {
            nativeGroups.forEach { surfaceTree.importStack($0, in: workspace) }
            if let selected = focusCoordinator.target ?? focus.windowOrNil?.surfaceID { surfaceTree.select(selected) }
        }
        func project(_ node: SurfaceTreeNode) -> WorkspaceSidebarItemViewModel? {
            switch node {
            case .surface(let id):
                if let row = available[id] { return row }
                return unresolvedNativeItems.contains(id) ? .init(kind: .surface(.init(surfaceID: id, title: "Waiting for owner", appName: "", isFocused: false))) : nil
            case .group(let id, let children):
                let visible = children.compactMap(project)
                return visible.isEmpty ? nil : .init(kind: .surfaceGroup(id, visible))
            }
        }
        return (surfaceTree.roots[workspace] ?? []).compactMap(project)
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

    func didMoveNativeSurface(_ id: SurfaceID, to workspace: String) {
        guard usesSurfaceTree else { return }
        if let old = surfaceTree.workspace(of: id), mixedLayoutWorkspaces.contains(old) {
            mixedLayoutWorkspaces.insert(workspace)
        }
        _ = surfaceTree.moveToRoot(id, in: workspace)
        scheduleRefresh()
    }

    func containsBrowserItems(in workspace: String) -> Bool {
        usesSurfaceTree && (placements.values.contains(workspace) ||
            (surfaceTree.roots[workspace] ?? []).flatMap(\.surfaces).contains(where: unresolvedNativeItems.contains))
    }

    func moveWorkspaceContents(from source: String, to target: String) {
        guard source != target else { return }
        for (id, workspace) in placements where workspace == source { placements[id] = target }
        if mixedLayoutWorkspaces.remove(source) != nil { mixedLayoutWorkspaces.insert(target) }
        surfaceTree.mergeWorkspace(source, into: target)
        scheduleRefresh()
    }

    private func plannedSurfaces(in workspace: Workspace) -> [SurfacePlacement] {
        let rect = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        return surfaceTree.placements(in: workspace.name, frame: .init(x: Int(rect.topLeftX.rounded()),
            y: Int(rect.topLeftY.rounded()), width: Int(rect.width.rounded()), height: Int(rect.height.rounded())),
            visible: workspace.isVisible)
    }

    func isHiddenInMixedLayout(_ id: SurfaceID, workspace: Workspace) -> Bool {
        guard TrayMenuModel.shared.isEnabled, mixedLayoutWorkspaces.contains(workspace.name) else { return false }
        return plannedSurfaces(in: workspace).first { $0.surfaceID == id }?.visible == false
    }

    func applyNativeLayout(in workspace: Workspace) async throws -> Bool {
        guard TrayMenuModel.shared.isEnabled, usesSurfaceTree, BrowserNativeManagement.lease != nil, mixedLayoutWorkspaces.contains(workspace.name) else { return false }
        let placements = plannedSurfaces(in: workspace)
        for placement in placements {
            guard let window = Window.get(bySurfaceID: placement.surfaceID), window.nodeWorkspace === workspace else { continue }
            if placement.visible {
                let frame = placement.frame
                let rect = Rect(topLeftX: Double(frame.x), topLeftY: Double(frame.y), width: Double(frame.width), height: Double(frame.height))
                if window.lastAppliedLayoutPhysicalRect != rect {
                    window.lastAppliedLayoutPhysicalRect = rect
                    window.lastAppliedLayoutVirtualRect = rect
                    window.setAxFrame(rect.topLeftCorner, CGSize(width: frame.width, height: frame.height))
                }
            } else if let native = window as? MacWindow {
                window.lastAppliedLayoutPhysicalRect = nil
                window.lastAppliedLayoutVirtualRect = nil
                try await native.hideInCorner(.bottomRightCorner)
            }
        }
        return !placements.isEmpty
    }

    func publishBrowserLayouts() {
        guard usesSurfaceTree, BrowserNativeManagement.lease != nil else { return }
        let placements = TrayMenuModel.shared.isEnabled ? Workspace.all.filter { mixedLayoutWorkspaces.contains($0.name) }.flatMap(plannedSurfaces) : []
        for session in sessions.values where session.supportsLayout {
            let owned = placements.filter { owner(of: $0.surfaceID) === session }
            let grouped = Dictionary(grouping: owned) { placement -> String in
                guard case .browserTab(let profile, _) = placement.surfaceID else { return "" }
                return "\(placement.containerID):\(profile)"
            }
            let hosts = grouped.keys.sorted().compactMap { key -> BrowserHostPlacement? in
                guard let items = grouped[key], let first = items.first else { return nil }
                let visible = items.first { $0.visible }
                return BrowserHostPlacement(containerID: first.containerID, surfaces: items.map(\.surfaceID),
                    selected: visible?.surfaceID, frame: first.frame, visible: visible != nil)
            }
            let target = focusCoordinator.target, generation = focusCoordinator.generation
            session.requestLayout(hosts) { [weak self, weak session] reply in
                guard reply == .issued, TrayMenuModel.shared.isEnabled, let self, let session, let target,
                      self.focusCoordinator.isCurrent(generation, target: target) else { return }
                if case .nativeWindow = target {
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

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task { @MainActor in
            self.refreshPending = false
            if self.previewWindow != nil { self.refreshPreview() }
            if isWinMuxRuntimeReady {
                await updateWorkspaceSidebarModel()
                if !self.mixedLayoutWorkspaces.isEmpty { runWorkspaceSidebarSession {} }
                if let selected = self.restoredSelection, self.isAvailable(selected) {
                    _ = self.select(selected)
                }
                RestartSessionController.shared.checkpoint()
            }
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
        snapshot.projects = [.init(id: workspaceProjectDefaultId, displayName: "WinMux Alpha", colorHex: nil)]
        snapshot.workspaces = [.init(name: "browser-alpha", projectId: workspaceProjectDefaultId,
            displayName: "Browser tabs", sidebarLabel: "", isGeneratedName: false,
            monitorScopeId: workspaceSidebarDefaultScopeId, monitorName: "", isFocused: true, isVisible: true,
            items: organizedRows(native: [], in: "browser-alpha"))]
        previewState.snapshot = snapshot
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
