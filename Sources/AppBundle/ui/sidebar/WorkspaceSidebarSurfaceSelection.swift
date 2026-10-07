import WorkspaceCore

/// Stack selection belongs to the layout, not Chromium's host-selected flag or
/// global keyboard focus. Split containers do not select all their visible leaves.
func workspaceSidebarSelectedSurfaces(in tree: SurfaceTree) -> Set<SurfaceID> {
    var selected: Set<SurfaceID> = []
    func visit(_ node: SurfaceTreeNode) {
        guard case .group(let id, let children) = node else { return }
        if tree.layouts[id] ?? .stack == .stack,
           let active = tree.activeSurfaces[id] ?? node.surfaces.first {
            selected.insert(active)
        }
        children.forEach(visit)
    }
    tree.roots.values.flatMap { $0 }.forEach(visit)
    return selected
}
