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
    private var placements: [SurfaceID: String] = [:]
    private var previewWindow: NSWindow?
    private let previewState = BrowserSidebarPreviewState()
    private var refreshPending = false

    public func connected(_ connection: UUID, processID: Int32, send: @escaping BrowserSurfaceSession.Transport) {
        processBindings = processBindings.filter { _, binding in
            binding.pid != processID && NSRunningApplication(processIdentifier: binding.pid)?.isTerminated == false
        }
        processBindings[connection] = (processID, NSRunningApplication(processIdentifier: processID)?.launchDate)
        sessions[connection] = BrowserSurfaceSession(focusCoordinator: focusCoordinator, send: send)
    }

    public func received(_ message: BrowserInventoryMessage, epoch: UUID, connection: UUID) {
        guard let session = sessions[connection] else { return }
        if session.epoch == nil { session.connect(epoch: epoch) }
        guard session.reconcile(message, epoch: epoch) else { return }
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
                guard Window.get(bySurfaceID: id)?.toLiveFocusOrNil() != nil else { return .unavailable }
                guard let generation = focusCoordinator.select(id) else { return .unavailable }
                let result = NativeWindowSurfaceAdapter(surfaceID: id).requestFocus()
                for session in sessions.values {
                    session.supersedeFocus(generation: generation, target: id) { [weak self] outcome in
                        guard outcome == .issued, let self,
                              self.focusCoordinator.isCurrent(generation, target: id) else { return }
                        // Never wait for a stalled browser to switch native apps.
                        // Reaffirm only this still-current, live native target after
                        // the browser queue has retired its earlier focus work.
                        _ = NativeWindowSurfaceAdapter(surfaceID: id).requestFocus()
                    }
                }
                scheduleRefresh()
                return result
        }
    }

    func close(_ id: SurfaceID) {
        guard let session = owner(of: id) else { return }
        _ = BrowserTabSurfaceAdapter(surfaceID: id, session: session).requestClose()
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
        window.contentView = NSHostingView(rootView: BrowserSidebarPreviewView(state: previewState,
            actions: WorkspaceSidebarActions(send: { [weak self] action in
                switch action {
                    case .selectSurface(let id): _ = self?.select(id)
                    case .closeSurface(let id): self?.close(id)
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
            items: rows(in: "browser-alpha"))]
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
