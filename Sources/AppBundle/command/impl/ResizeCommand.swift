import AppKit
import Common
import WorkspaceCore

struct ResizeCommand: Command {
    let args: ResizeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        let controller = BrowserWorkspaceController.shared
        if let id = args.sharedOrganizationTarget(env),
           let name = controller.workspaceName(for: id), let workspace = Workspace.existing(byName: name) {
            let dimension: SurfaceResizeDimension = switch args.dimension.val {
                case .width: .width
                case .height: .height
                case .smart: .smart
                case .smartOpposite: .smartOpposite
            }
            let amount: Double
            let absolute: Bool
            switch args.units.val {
            case .set(let value): amount = Double(value); absolute = true
            case .add(let value): amount = Double(value); absolute = false
            case .subtract(let value): amount = -Double(value); absolute = false
            }
            return controller.resizeSurface(id, in: workspace, dimension: dimension, amount: amount, absolute: absolute)
                || io.err("Cannot resize this surface: no matching split or its minimum size has been reached")
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }

        let candidates = target.windowOrNil?.parentsWithSelf
            .filter { ($0.parent as? TilingContainer)?.layout == .tiles }
            ?? []

        let orientation: Orientation?
        let parent: TilingContainer?
        let node: TreeNode?
        switch args.dimension.val {
            case .width:
                orientation = .h
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .height:
                orientation = .v
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .smart:
                node = candidates.first
                parent = node?.parent as? TilingContainer
                orientation = parent?.orientation
            case .smartOpposite:
                orientation = (candidates.first?.parent as? TilingContainer)?.orientation.opposite
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
        }
        guard let parent else { return io.err("resize command doesn't support floating windows yet https://github.com/nikitabobko/WinMux/issues/9") }
        guard let orientation else { return false }
        guard let node else { return false }
        let requestedDiff: CGFloat = switch args.units.val {
            case .set(let unit): CGFloat(unit) - node.getWeight(orientation)
            case .add(let unit): CGFloat(unit)
            case .subtract(let unit): -CGFloat(unit)
        }

        let siblings = parent.children.filter { $0 != node }
        guard !siblings.isEmpty else { return false }
        let siblingMultiplier = -CGFloat(1).div(siblings.count).orDie()
        let diff = constrainedTiledResizeDiff(
            requestedDiff,
            adjustments: [TiledResizeAdjustment(weight: node.getWeight(orientation), multiplier: 1)] +
                siblings.map { TiledResizeAdjustment(weight: $0.getWeight(orientation), multiplier: siblingMultiplier) },
        )
        let childDiff = diff.div(siblings.count).orDie()
        siblings
            .forEach { $0.setWeight(parent.orientation, $0.getWeight(parent.orientation) - childDiff) }

        node.setWeight(orientation, node.getWeight(orientation) + diff)
        return true
    }
}
