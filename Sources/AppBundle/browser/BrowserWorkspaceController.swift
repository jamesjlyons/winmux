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
    private var placements: [SurfaceID: String] = [:]
    private var previewWindow: NSWindow?
    private let previewState = BrowserSidebarPreviewState()
    private var refreshPending = false
    private var browserFocusDeadline: Date?

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

    public func connected(_ connection: UUID, processID: Int32, send: @escaping BrowserSurfaceSession.Transport) {
        processBindings = processBindings.filter { _, binding in
            binding.pid != processID && NSRunningApplication(processIdentifier: binding.pid)?.isTerminated == false
        }
        processBindings[connection] = (processID, NSRunningApplication(processIdentifier: processID)?.launchDate)
        sessions[connection] = BrowserSurfaceSession(focusCoordinator: focusCoordinator, send: send)
        reconcileNativeHosts()
    }

    public func received(_ message: BrowserInventoryMessage, epoch: UUID, connection: UUID) {
        guard let session = sessions[connection] else { return }
        if session.epoch == nil { session.connect(epoch: epoch) }
        let oldIDs = Set(session.inventory.tabs.keys)
        guard session.reconcile(message, epoch: epoch) else { return }
        for id in oldIDs.subtracting(session.inventory.tabs.keys) where owner(of: id) == nil {
            placements.removeValue(forKey: id)
            surfaceTree.remove(id)
        }
        let workspace = previewWindow == nil ? focus.workspace.name : "browser-alpha"
        for id in session.inventory.tabs.keys where placements[id] == nil { placements[id] = workspace }
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
        let leavingBrowser = hasBrowserSelection
        browserFocusDeadline = nil
        guard !sessions.isEmpty, let generation = focusCoordinator.select(id) else { return }
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
        switch id {
            case .browserTab:
                guard let session = owner(of: id) else { return .unavailable }
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

    func close(_ id: SurfaceID) {
        if case .nativeWindow = id {
            _ = NativeWindowSurfaceAdapter(surfaceID: id).requestClose()
        } else if let session = owner(of: id) {
            _ = BrowserTabSurfaceAdapter(surfaceID: id, session: session).requestClose()
        }
    }

    func organizedRows(native: [WorkspaceSidebarItemViewModel], in workspace: String) -> [WorkspaceSidebarItemViewModel] {
        guard usesSurfaceTree else { return native + rows(in: workspace) }
        var available: [SurfaceID: WorkspaceSidebarItemViewModel] = [:]
        var ordered: [SurfaceID] = []
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
            case .tabGroup(let group): group.tabs.forEach { collect(.init(kind: .window($0))) }
            case .surface, .surfaceGroup: break
            }
        }
        (native + rows(in: workspace)).forEach(collect)
        surfaceTree.reconcile(ordered, in: workspace,
                              retaining: Set(placements.filter { $0.value == workspace }.map(\.key)))
        func project(_ node: SurfaceTreeNode) -> WorkspaceSidebarItemViewModel? {
            switch node {
            case .surface(let id): return available[id]
            case .group(let id, let children):
                let visible = children.compactMap(project)
                return visible.isEmpty ? nil : .init(kind: .surfaceGroup(id, visible))
            }
        }
        return (surfaceTree.roots[workspace] ?? []).compactMap(project)
    }

    /// Organization never implies host movement or completed focus. Native owners
    /// are revalidated at dispatch; browser profile identity is preserved.
    func organize(_ id: SurfaceID, before target: SurfaceID? = nil, earlier: Bool? = nil, groupWithSelection: Bool = false) {
        guard usesSurfaceTree, isAvailable(id) else { return }
        if let target {
            guard isAvailable(target) else { return }
            _ = surfaceTree.move(id, before: target)
        } else if let earlier { _ = surfaceTree.reorder(id, earlier: earlier) }
        else if groupWithSelection, let target = focusCoordinator.target, isAvailable(target) {
            _ = surfaceTree.group(id, with: target)
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
        guard usesSurfaceTree, owner(of: id) != nil else { return }
        placements[id] = workspace
        _ = surfaceTree.moveToRoot(id, in: workspace)
        scheduleRefresh()
    }

    func containsBrowserItems(in workspace: String) -> Bool {
        usesSurfaceTree && placements.values.contains(workspace)
    }

    func moveWorkspaceContents(from source: String, to target: String) {
        guard source != target else { return }
        for (id, workspace) in placements where workspace == source { placements[id] = target }
        surfaceTree.mergeWorkspace(source, into: target)
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task { @MainActor in
            self.refreshPending = false
            if self.previewWindow != nil { self.refreshPreview() }
            if isWinMuxRuntimeReady { await updateWorkspaceSidebarModel() }
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
