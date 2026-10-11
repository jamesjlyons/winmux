import Foundation

struct NativePresentationRevision: Equatable {
    let structure: UInt64
    let selection: UInt64
    let metadata: UInt64
    let configuration: UInt64
    let focusedWindow: UInt32?
    // Revisit the title cache lazily; no timer or AX query for each pointer event.
    let titleEpoch: Int

    @MainActor init(_ node: TreeNode, workspace: Workspace, currentFocus: LiveFocus) {
        structure = node.revisions.structure
        selection = node.revisions.selection
        metadata = node.revisions.metadata
        configuration = configurationRevision
        focusedWindow = currentFocus.workspace === workspace && !BrowserWorkspaceController.shared.hasBrowserSelection
            ? currentFocus.windowOrNil?.windowId : nil
        titleEpoch = Int(ProcessInfo.processInfo.systemUptime / 5)
    }
}

/// Session callers enqueue chrome after placement/focus. A suspended AX read
/// cannot hold up command completion; new requests invalidate older publication.
@MainActor
final class InteractionChromeScheduler {
    static let shared = InteractionChromeScheduler()
    private var task: Task<Void, Never>?
    private var requested = false

    func schedule() {
        guard !AppShutdownCoordinator.shared.isShuttingDown else { return }
        requested = true
        guard task == nil else { return }
        task = Task { @MainActor in
            defer { self.task = nil }
            while self.requested && !Task.isCancelled {
                self.requested = false
                await updateWorkspaceSidebarModel()
                await updateWindowTabModel()
            }
        }
    }

    func flush() async { await task?.value }
    func cancel() { requested = false; task?.cancel() }
}
