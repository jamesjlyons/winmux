import AppKit
import Common

@MainActor
func bindingDataForDwindleArrival(_ workspace: Workspace) -> BindingData? {
    let focused = focus.windowOrNil.flatMap { $0.nodeWorkspace === workspace && $0.parent is TilingContainer ? $0 : nil }
    guard let window = focused ?? workspace.mostRecentWindowRecursive,
          window.parent is TilingContainer else { return nil }
    var anchor: TreeNode = window
    // Keep explicit stacks intact when the arrival policy calls for tiling.
    while let parent = anchor.parent as? TilingContainer, parent.layout == .tabGroup { anchor = parent }
    let size = dwindlePaneSize(anchor, in: workspace)
    let axis: Orientation = size.width >= size.height ? .h : .v
    if let parent = anchor.parent as? TilingContainer {
        if parent.children.count == 1 { parent.changeOrientation(axis) }
        if parent.orientation == axis {
            return BindingData(parent: parent, adaptiveWeight: WEIGHT_AUTO, index: anchor.ownIndex.orDie() + 1)
        }
        let binding = anchor.unbindFromParent()
        let split = TilingContainer(parent: parent, adaptiveWeight: binding.adaptiveWeight, axis, .tiles, index: binding.index)
        anchor.bind(to: split, adaptiveWeight: WEIGHT_AUTO, index: 0)
        return BindingData(parent: split, adaptiveWeight: WEIGHT_AUTO, index: 1)
    }
    // A stack may itself be the workspace root.
    guard anchor === workspace.rootTilingContainer else { return nil }
    anchor.unbindFromParent()
    let root = TilingContainer(parent: workspace, adaptiveWeight: WEIGHT_AUTO, axis, .tiles, index: 0)
    anchor.bind(to: root, adaptiveWeight: WEIGHT_AUTO, index: 0)
    return BindingData(parent: root, adaptiveWeight: WEIGHT_AUTO, index: 1)
}

@MainActor
private func dwindlePaneSize(_ node: TreeNode, in workspace: Workspace) -> CGSize {
    if let rect = node.lastAppliedLayoutPhysicalRect { return CGSize(width: rect.width, height: rect.height) }
    guard let parent = node.parent as? TilingContainer else {
        let rect = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        return CGSize(width: rect.width, height: rect.height)
    }
    var size = dwindlePaneSize(parent, in: workspace)
    if parent.layout == .tiles {
        let total = parent.children.reduce(CGFloat.zero) { $0 + $1.getWeight(parent.orientation) }
        let ratio = total > 0 ? node.getWeight(parent.orientation) / total : 1 / CGFloat(parent.children.count)
        if parent.orientation == .h { size.width *= ratio } else { size.height *= ratio }
    }
    return size
}
