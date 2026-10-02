import AppKit
import Common
import WorkspaceCore

extension BrowserWorkspaceController {
    func navigationStackItems(for id: SurfaceID, in workspace: Workspace) -> [SurfaceID] {
        if let items = surfaceTree.stackItems(containing: id) { return items.filter(isAvailable) }
        // A split that cannot fit is temporarily presented as a stack without
        // rewriting the saved tree. Keep it navigable through the same controls.
        let plan = plannedSurfaces(in: workspace)
        return plan.filter(\.visible).count == 1 ? plan.map(\.surfaceID).filter(isAvailable) : []
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
            func axis(_ p: SurfacePlacement) -> Int { direction.orientation == .h ? p.frame.x + p.frame.width / 2 : p.frame.y + p.frame.height / 2 }
            let others = frames.filter { $0.visible && $0.surfaceID != current && isAvailable($0.surfaceID) }
            let forward = others.filter { direction.isPositive ? axis($0) > axis(source) : axis($0) < axis(source) }
            if let next = forward.min(by: { abs(axis($0) - axis(source)) < abs(axis($1) - axis(source)) }) {
                return select(next.surfaceID) == .issued
            }
            if args.boundariesAction == .wrapAroundTheWorkspace,
               let next = others.min(by: { direction.isPositive ? axis($0) < axis($1) : axis($0) > axis($1) }) {
                return select(next.surfaceID) == .issued
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

    @MainActor static func capture(_ controller: BrowserWorkspaceController = .shared) -> Self? {
        guard controller.usesSurfaceTree, let id = controller.focusCoordinator.target,
              let workspace = controller.surfaceTree.workspace(of: id), let live = Workspace.existing(byName: workspace), live.isVisible,
              controller.navigationStackItems(for: id, in: live).count > 1,
              let pid = controller.navigationProcess(for: id) else { return nil }
        return .init(surface: id, workspace: workspace, tree: controller.surfaceTree, generation: controller.focusCoordinator.generation, pid: pid)
    }

    @MainActor func commit(next: Bool, controller: BrowserWorkspaceController = .shared) -> Bool {
        guard controller.surfaceTree == tree, controller.focusCoordinator.isCurrent(generation, target: surface),
              controller.navigationProcess(for: surface) == pid, let workspace = Workspace.existing(byName: workspace), workspace.isVisible else { return false }
        var args = FocusCmdArgs(rawArgs: [], targetArg: .tabRelative(next ? .tabNext : .tabPrev))
        args.rawBoundariesAction = .wrapAroundTheWorkspace
        return controller.navigate(args, workspace: workspace) == true
    }
}
