import WorkspaceCore

extension BrowserWorkspaceController {
    /// WinMux fullscreen expands the shared stack containing the requesting
    /// native window. Switching its selected tab keeps that stack fullscreen.
    /// macOS native fullscreen remains an owner observation outside this plan.
    func sharedFullscreenPane(in workspace: Workspace) -> (pane: SurfacePane, noOuterGaps: Bool)? {
        guard usesSurfaceTree, hasSharedLayout(in: workspace) else { return nil }
        // Most checks come from sidebar insets and chrome visibility. No live
        // projection is needed unless a native owner requested WinMux fullscreen.
        guard (surfaceTree.roots[workspace.name] ?? []).contains(where: { node in
            node.surfaces.contains { Window.get(bySurfaceID: $0)?.isFullscreen == true }
        }) else { return nil }
        return sharedFullscreenPane(in: workspace, liveTree: liveLayoutTree(in: workspace))
    }

    /// A layout pass already projected its live owners; use that exact tree for
    /// fullscreen selection without repeating inventory and native-state reads.
    func sharedFullscreenPane(in workspace: Workspace, liveTree live: SurfaceTree) -> (pane: SurfacePane, noOuterGaps: Bool)? {
        guard usesSurfaceTree, hasSharedLayout(in: workspace) else { return nil }
        let ids = (live.roots[workspace.name] ?? []).flatMap(\.surfaces)
        let candidates = ids.compactMap(Window.get(bySurfaceID:)).filter(\.isFullscreen)
        guard !candidates.isEmpty else { return nil }
        for window in candidates {
            if let stack = live.stack(containing: window.surfaceID) {
                return (.group(stack), window.noOuterGapsInFullscreen)
            }
        }
        let selected = focusCoordinator.target.flatMap { ids.contains($0) ? $0 : nil }
            ?? selectedByWorkspace[workspace.name].flatMap { ids.contains($0) ? $0 : nil }
            ?? workspace.existingRootTilingContainer?.mostRecentWindowRecursive?.surfaceID
        guard let window = candidates.first(where: { $0.surfaceID == selected }) else { return nil }
        return (.surface(window.surfaceID), window.noOuterGapsInFullscreen)
    }
}
