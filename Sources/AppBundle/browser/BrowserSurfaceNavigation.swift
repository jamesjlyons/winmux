import AppKit
import Common
import WorkspaceCore

/// Keep directional focus in the current row or column when the layout wraps.
/// Primary-axis ties use the nearest orthogonal center, never tree order.
func browserDirectionalSurface(from source: SurfacePlacement, others: [SurfacePlacement],
                               direction: CardinalDirection, wrapping: Bool) -> SurfaceID? {
    func axis(_ placement: SurfacePlacement) -> Int {
        direction.orientation == .h ? placement.frame.x + placement.frame.width / 2
            : placement.frame.y + placement.frame.height / 2
    }
    func cross(_ placement: SurfacePlacement) -> (Int, Int) {
        direction.orientation == .h ? (placement.frame.y, placement.frame.y + placement.frame.height)
            : (placement.frame.x, placement.frame.x + placement.frame.width)
    }
    let sourceCross = cross(source)
    func alignment(_ placement: SurfacePlacement) -> (Int, Int) {
        let bounds = cross(placement)
        let overlaps = max(sourceCross.0, bounds.0) < min(sourceCross.1, bounds.1)
        return (overlaps ? 0 : 1, abs((bounds.0 + bounds.1) - (sourceCross.0 + sourceCross.1)))
    }
    let available = others.filter { $0.visible && $0.surfaceID != source.surfaceID }
    let forward = available.filter { direction.isPositive ? axis($0) > axis(source) : axis($0) < axis(source) }
    if let next = forward.min(by: {
        let left = alignment($0), right = alignment($1)
        return (left.0, abs(axis($0) - axis(source)), left.1)
            < (right.0, abs(axis($1) - axis(source)), right.1)
    }) { return next.surfaceID }
    guard wrapping else { return nil }
    return available.min(by: {
        let left = alignment($0), right = alignment($1)
        let leftEdge = direction.isPositive ? axis($0) : -axis($0)
        let rightEdge = direction.isPositive ? axis($1) : -axis($1)
        return (left.0, leftEdge, left.1) < (right.0, rightEdge, right.1)
    })?.surfaceID
}

extension BrowserWorkspaceController {
    func navigationStackItems(for id: SurfaceID, in workspace: Workspace) -> [SurfaceID] {
        guard hasMixedLayout(in: workspace) else {
            return surfaceTree.stackItems(containing: id)?.filter(isAvailable) ?? []
        }
        // Geometry and navigation share the same nearest effective container.
        // Counting all visible leaves loses nested temporary stack boundaries.
        return plannedSurfaces(in: workspace).first { $0.surfaceID == id }?.navigationStack.filter(isAvailable) ?? []
    }
    /// Numeric native IDs keep their existing meaning. Shared traversal is alpha-only.
    func navigate(_ args: FocusCmdArgs, workspace: Workspace, from explicit: SurfaceID? = nil) -> Bool? {
        guard usesSurfaceTree, let nodes = surfaceTree.roots[workspace.name] else { return nil }
        let current = explicit ?? focusCoordinator.target ?? focus.windowOrNil?.surfaceID
        let all = nodes.flatMap(\.surfaces).filter(isAvailable)
        var items = all
        var offset: Int?, index: Int?
        switch args.target {
        case .windowId: return nil
        case .dfsIndex(let i): index = Int(i)
        case .dfsRelative(let direction): offset = direction == .dfsNext ? 1 : -1
        case .tabIndex(let i):
            items = current.map { navigationStackItems(for: $0, in: workspace) } ?? []
            index = Int(i) - 1
        case .tabRelative(let direction):
            items = current.map { navigationStackItems(for: $0, in: workspace) } ?? []
            offset = direction == .tabNext ? 1 : -1
        case .direction(let direction):
            guard args.boundaries == .workspace else { return nil }
            let frames = plannedSurfaces(in: workspace)
            guard let source = frames.first(where: { $0.surfaceID == current }) else { return false }
            let others = frames.filter { $0.visible && $0.surfaceID != current && isAvailable($0.surfaceID) }
            if let next = browserDirectionalSurface(from: source, others: others, direction: direction,
                                                     wrapping: args.boundariesAction == .wrapAroundTheWorkspace) {
                return select(next) == .issued
            }
            return args.boundariesAction != .fail
        }
        if let offset {
            guard let current, let start = items.firstIndex(of: current) else { return false }
            index = start + offset
            if !items.indices.contains(index!) {
                guard args.boundariesAction == .wrapAroundTheWorkspace else { return args.boundariesAction != .fail }
                index = (index! + items.count) % items.count
            }
        }
        guard let index, items.indices.contains(index) else { return false }
        return select(items[index]) == .issued
    }

    func navigationProcess(for id: SurfaceID) -> Int32? {
        if case .nativeWindow = id { return Window.get(bySurfaceID: id)?.app.pid }
        return browserProcess(for: id)
    }
}

struct MixedTrackpadTarget {
    let surface: SurfaceID
    let workspace: String
    let tree: SurfaceTree
    let generation: UInt64
    let pid: Int32
    let stackItems: [SurfaceID]

    @MainActor static func capture(_ controller: BrowserWorkspaceController = .shared) -> Self? {
        guard controller.usesSurfaceTree, let id = controller.focusCoordinator.target,
              let workspace = controller.surfaceTree.workspace(of: id), let live = Workspace.existing(byName: workspace), live.isVisible,
              let pid = controller.navigationProcess(for: id) else { return nil }
        let stackItems = controller.navigationStackItems(for: id, in: live)
        guard stackItems.count > 1 else { return nil }
        return .init(surface: id, workspace: workspace, tree: controller.surfaceTree,
                     generation: controller.focusCoordinator.generation, pid: pid, stackItems: stackItems)
    }

    @MainActor func commit(next: Bool, controller: BrowserWorkspaceController = .shared) -> Bool {
        guard controller.surfaceTree == tree, controller.focusCoordinator.isCurrent(generation, target: surface),
              controller.navigationProcess(for: surface) == pid, let workspace = Workspace.existing(byName: workspace), workspace.isVisible,
              controller.navigationStackItems(for: surface, in: workspace) == stackItems else { return false }
        var args = FocusCmdArgs(rawArgs: [], targetArg: .tabRelative(next ? .tabNext : .tabPrev))
        args.rawBoundariesAction = .wrapAroundTheWorkspace
        return controller.navigate(args, workspace: workspace) == true
    }
}
