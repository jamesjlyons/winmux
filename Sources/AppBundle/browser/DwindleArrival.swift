import WorkspaceCore

extension BrowserWorkspaceController {
    /// Both inventory discovery and new-tab replies may place the same page.
    /// Plan without it so either arrival order chooses the same split axis.
    @discardableResult
    func placeTiledArrival(_ id: SurfaceID, in name: String, after source: SurfaceID?) -> Bool {
        guard usesSurfaceTree, config.newItemPlacement != .newView,
              let workspace = Workspace.existing(byName: name), !workspace.isPinnedGroup else { return false }
        var tree = liveLayoutTree(in: workspace)
        tree.remove(id)
        let members = (tree.roots[name] ?? []).flatMap(\.surfaces)
        let anchor = [source, preferredSurface(in: workspace)].compactMap { $0 }.first(where: members.contains)
            ?? members.last
        guard let anchor else { return false }
        if surfaceTree.workspace(of: id) != name {
            surfaceTree.reconcile((surfaceTree.roots[name] ?? []).flatMap(\.surfaces) + [id], in: name)
        }
        if config.tilingAlgorithm == .adaptive { return surfaceTree.insertAdaptive(id, beside: anchor) }
        let rect = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        let plan = tree.layout(in: name, frame: .init(x: Int(rect.topLeftX.rounded()), y: Int(rect.topLeftY.rounded()),
            width: Int(rect.width.rounded()), height: Int(rect.height.rounded())), visible: true,
            minimumSizes: minimumSizes(in: workspace), selectedSurface: anchor, recentSelections: recentSelections,
            stackChrome: stackChrome(in: workspace), gaps: layoutGaps(in: workspace))
        let pane = tree.ancestors(of: .surface(anchor)).first(where: {
            if case .group(let group, _) = $0 { return (tree.layouts[group] ?? .stack) == .stack }
            return false
        })?.pane ?? .surface(anchor)
        guard let frame = plan.frames[pane] else { return false }
        return surfaceTree.insertDwindle(id, beside: anchor, frame: frame)
    }
}
