import AppKit

/// Small layout inputs. Reading this does not enumerate a workspace's windows.
/// Output frames intentionally do not participate: an animation cannot dirty
/// its own layout just by advancing a presentation frame.
struct WorkspaceLayoutRevision: Equatable {
    let workspaceID: WorkspaceId
    let structure: UInt64
    let selection: UInt64
    let geometry: UInt64
    let metadata: UInt64
    let configuration: UInt64
    let browser: UInt64
    let browserSelection: UInt64
    let browserFocus: UInt64
    let visible: Bool
    let monitor: Rect
    let available: Rect
    let padded: Rect

    @MainActor init(_ workspace: Workspace, controller: BrowserWorkspaceController = .shared, includeBrowser: Bool = true) {
        workspaceID = workspace.id
        structure = workspace.revisions.structure
        selection = workspace.revisions.selection
        geometry = workspace.revisions.geometry
        metadata = workspace.revisions.metadata
        configuration = configurationRevision
        browser = includeBrowser ? controller.layoutEpoch : 0
        browserSelection = includeBrowser ? controller.layoutSelectionRevision(in: workspace) : 0
        browserFocus = includeBrowser && workspace.isVisible ? controller.focusCoordinator.generation : 0
        visible = workspace.isVisible
        monitor = workspace.workspaceMonitor.rect
        available = workspace.workspaceMonitor.visibleRect
        padded = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
    }
}

@MainActor
final class WorkspaceLayoutCache {
    static let shared = WorkspaceLayoutCache()
    private var completed: [ObjectIdentifier: WorkspaceLayoutRevision] = [:]
    private var generation: UInt64 = 0

    func invalidate() { completed.removeAll(); generation &+= 1 }
    func invalidate(workspaces: Set<Workspace>) {
        for workspace in workspaces { completed.removeValue(forKey: ObjectIdentifier(workspace)) }
        generation &+= 1
    }
    func prune(_ workspaces: [Workspace]) {
        let live = Set(workspaces.map(ObjectIdentifier.init))
        completed = completed.filter { live.contains($0.key) }
    }
    func needsLayout(_ workspace: Workspace, revision: WorkspaceLayoutRevision) -> Bool {
        completed[ObjectIdentifier(workspace)] != revision
    }
    func wasHidden(_ workspace: Workspace) -> Bool { completed[ObjectIdentifier(workspace)]?.visible == false }
    func token() -> UInt64 { generation }
    func record(_ workspace: Workspace, revision: WorkspaceLayoutRevision, token: UInt64) {
        guard token == generation else { return }
        completed[ObjectIdentifier(workspace)] = revision
    }
}
