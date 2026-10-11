import Foundation

/// Repairs already-hidden workspaces outside the input critical path. Newly
/// outgoing workspaces still park in the foreground layout pass.
@MainActor
final class HiddenLayoutMaintenance {
    static let shared = HiddenLayoutMaintenance()
    private var pending: [Workspace: OptimalHideCorner] = [:]
    private var task: Task<Void, Never>?

    func schedule(_ workspace: Workspace, corner: OptimalHideCorner) {
        guard !AppShutdownCoordinator.shared.isShuttingDown else { return }
        pending[workspace] = corner
        guard task == nil else { return }
        task = Task { @MainActor in
            defer { self.task = nil }
            while let (workspace, corner) = self.pending.first, !Task.isCancelled {
                self.pending.removeValue(forKey: workspace)
                guard !workspace.isVisible else { continue }
                let cache = WorkspaceLayoutCache.shared
                let revision = WorkspaceLayoutRevision(workspace, includeBrowser: false)
                let token = cache.token()
                do {
                    let completed = try await parkHiddenWorkspace(workspace, corner: corner)
                    guard completed, !Task.isCancelled, !workspace.isVisible else { continue }
                    cache.record(workspace, revision: revision, token: token)
                } catch {
                    // Leave the revision dirty; the next refresh can retry.
                }
            }
        }
    }

    func cancel() { pending.removeAll(); task?.cancel() }
    func flush() async { await task?.value }
}
