import Foundation
import WorkspaceCore

struct WorkspaceRestoreRevision: Equatable {
    let owner: ObjectIdentifier
    let revision: UInt64
    let monitor: FrozenMonitor

    @MainActor init(_ workspace: Workspace) {
        owner = ObjectIdentifier(workspace)
        revision = workspace.revisions.persistence
        monitor = FrozenMonitor(workspace.workspaceMonitor)
    }
}

/// Compares persisted inputs without building FrozenContainer/FrozenWindow
/// records. Captures remain deferred and encoding stays on RestartSessionWriter.
struct RestartSessionRevision: Equatable {
    let workspaces: [String: WorkspaceRestoreRevision]
    let minimized: UInt64
    let monitorSnapshots: [FrozenMonitor]
    let projects: [WorkspaceProjectId: WorkspaceProject]
    let focusedWorkspace: WorkspaceId
    let focusedWindow: UInt32?
    let browser: UInt64
    let selectedSurface: SurfaceID?

    @MainActor init() {
        workspaces = Dictionary(uniqueKeysWithValues: Workspace.all.filter { !$0.isArchived && !$0.isIncognito }.map {
            ($0.name, WorkspaceRestoreRevision($0))
        })
        minimized = macosMinimizedWindowsContainer.revisions.persistence
        monitorSnapshots = monitors.map(FrozenMonitor.init)
        projects = winMuxWorkspaceState.projectsById
        focusedWorkspace = focus.workspace.id
        focusedWindow = focus.windowOrNil?.windowId
        browser = BrowserWorkspaceController.shared.persistenceRevision
        selectedSurface = BrowserWorkspaceController.shared.focusCoordinator.target
    }
}
