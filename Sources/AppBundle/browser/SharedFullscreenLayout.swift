import WorkspaceCore

extension BrowserWorkspaceController {
    /// WinMux fullscreen expands the shared stack containing the requesting
    /// native window. Switching its selected tab keeps that stack fullscreen.
    /// macOS native fullscreen remains an owner observation outside this plan.
    func sharedFullscreenPane(in workspace: Workspace) -> (pane: SurfacePane, noOuterGaps: Bool)? {
        guard usesSurfaceTree, hasSharedLayout(in: workspace) else { return nil }
        let live = liveLayoutTree(in: workspace)
        let ids = (live.roots[workspace.name] ?? []).flatMap(\.surfaces)
        let candidates = ids.compactMap(Window.get(bySurfaceID:)).filter(\.isFullscreen)
        for window in candidates {
            if let stack = live.stack(containing: window.surfaceID) {
                return (.group(stack), window.noOuterGapsInFullscreen)
            }
        }
        let selected = focusCoordinator.target.flatMap { ids.contains($0) ? $0 : nil }
            ?? selectedByWorkspace[workspace.name].flatMap { ids.contains($0) ? $0 : nil }
            ?? workspace.rootTilingContainer.mostRecentWindowRecursive?.surfaceID
        guard let window = candidates.first(where: { $0.surfaceID == selected }) else { return nil }
        return (.surface(window.surfaceID), window.noOuterGapsInFullscreen)
    }
}
