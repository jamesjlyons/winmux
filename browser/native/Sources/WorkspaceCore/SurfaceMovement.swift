import Foundation

public enum SurfaceMoveOutcome: Equatable, Sendable {
    case moved, boundary, unavailable
}

extension SurfaceTree {
    /// Directional movement preserves explicit stacks as units, enters adjacent
    /// splits, and exits nested containers before reaching the View boundary.
    public mutating func move(_ surface: SurfaceID, toward direction: SurfaceDirection,
                              creatingContainerAtBoundary: Bool = false) -> SurfaceMoveOutcome {
        guard let workspace = workspace(of: surface), var nodes = roots[workspace],
              var path = movementPath(to: surface, in: nodes) else { return .unavailable }
        if path.count > 1, case .group(let parent, _)? = movementNode(at: Array(path.dropLast()), in: nodes),
           (layouts[parent] ?? .stack) == .stack { path.removeLast() }
        guard let moving = movementNode(at: path, in: nodes), let index = path.last else { return .unavailable }
        let parentPath = Array(path.dropLast())
        let parentNode = movementNode(at: parentPath, in: nodes)
        let parentKey = parentNode?.weightKey
        let siblings = movementChildren(of: parentNode, roots: nodes)
        let next = index + (direction.isPositive ? 1 : -1)

        if movementIsHorizontal(parentNode) == direction.isHorizontal, siblings.indices.contains(next) {
            let neighbor = siblings[next]
            if case .surface = moving, case .group(let group, _) = neighbor, (layouts[group] ?? .stack) != .stack {
                let insertion = movementInsertion(into: neighbor, parent: parentKey, index: next, direction: direction)
                guard editMovementChildren(in: &nodes, parent: parentKey, { $0.remove(at: index) }),
                      editMovementChildren(in: &nodes, parent: insertion.parent, { $0.insert(moving, at: insertion.index) }) else { return .unavailable }
            } else {
                guard editMovementChildren(in: &nodes, parent: parentKey, { $0.swapAt(index, next) }) else { return .unavailable }
            }
            finishMovement(nodes, in: workspace)
            return .moved
        }

        // The immediate container has no neighbor on this axis. Move outside
        // the nearest ancestor whose parent does arrange children on this axis.
        for depth in stride(from: parentPath.count, through: 1, by: -1) {
            let ancestorPath = Array(path.prefix(depth))
            let outer = movementNode(at: Array(ancestorPath.dropLast()), in: nodes)
            guard movementIsHorizontal(outer) == direction.isHorizontal, let anchor = ancestorPath.last else { continue }
            guard editMovementChildren(in: &nodes, parent: parentKey, { $0.remove(at: index) }),
                  editMovementChildren(in: &nodes, parent: outer?.weightKey, {
                      $0.insert(moving, at: anchor + (direction.isPositive ? 1 : 0))
                  }) else { return .unavailable }
            finishMovement(nodes, in: workspace)
            return .moved
        }

        guard creatingContainerAtBoundary else { return .boundary }
        guard editMovementChildren(in: &nodes, parent: parentKey, { $0.remove(at: index) }) else { return .unavailable }
        let remaining = retainingNodes(nodes, keeping: Set(nodes.flatMap(\.surfaces)))
        guard !remaining.isEmpty else { return .moved }
        let anchor: SurfaceTreeNode
        if remaining.count == 1 { anchor = remaining[0] }
        else {
            let group = UUID()
            layouts[group] = .horizontal
            anchor = .group(group, remaining)
        }
        let children = direction.isPositive ? [anchor, moving] : [moving, anchor]
        weights[anchor.weightKey] = 1; weights[moving.weightKey] = 1
        if direction.isHorizontal { nodes = children }
        else {
            let group = UUID()
            layouts[group] = .vertical
            nodes = [.group(group, children)]
        }
        finishMovement(nodes, in: workspace)
        return .moved
    }

    private func movementIsHorizontal(_ node: SurfaceTreeNode?) -> Bool {
        guard case .group(let id, _)? = node else { return true }
        return (layouts[id] ?? .stack) != .vertical
    }

    private func movementInsertion(into node: SurfaceTreeNode, parent: String?, index: Int,
                                   direction: SurfaceDirection) -> (parent: String?, index: Int) {
        guard case .group(let id, let children) = node, !children.isEmpty else { return (parent, index + 1) }
        if movementIsHorizontal(node) == direction.isHorizontal || (layouts[id] ?? .stack) == .stack {
            return (node.weightKey, 0)
        }
        let selected = activeSurfaces[id].flatMap { selected in children.firstIndex { $0.surfaces.contains(selected) } } ?? 0
        return movementInsertion(into: children[selected], parent: node.weightKey, index: selected, direction: direction)
    }

    private mutating func finishMovement(_ nodes: [SurfaceTreeNode], in workspace: String) {
        // Membership can be unchanged while a selected leaf leaves a container.
        // Prune structural metadata even when owner reconciliation would no-op.
        roots[workspace] = retainingNodes(nodes, keeping: Set(nodes.flatMap(\.surfaces)))
        pruneMetadata()
    }
}

private func movementPath(to surface: SurfaceID, in nodes: [SurfaceTreeNode]) -> [Int]? {
    for (index, node) in nodes.enumerated() {
        switch node {
        case .surface(surface): return [index]
        case .group(_, let children):
            if let path = movementPath(to: surface, in: children) { return [index] + path }
        default: break
        }
    }
    return nil
}

private func movementNode(at path: [Int], in nodes: [SurfaceTreeNode]) -> SurfaceTreeNode? {
    guard let first = path.first, nodes.indices.contains(first) else { return nil }
    if path.count == 1 { return nodes[first] }
    guard case .group(_, let children) = nodes[first] else { return nil }
    return movementNode(at: Array(path.dropFirst()), in: children)
}

private func movementChildren(of node: SurfaceTreeNode?, roots: [SurfaceTreeNode]) -> [SurfaceTreeNode] {
    if case .group(_, let children)? = node { return children }
    return roots
}

private func editMovementChildren(in nodes: inout [SurfaceTreeNode], parent: String?, _ edit: (inout [SurfaceTreeNode]) -> Void) -> Bool {
    guard let parent else { edit(&nodes); return true }
    for index in nodes.indices {
        guard case .group(let id, var children) = nodes[index] else { continue }
        if nodes[index].weightKey == parent {
            edit(&children); nodes[index] = .group(id, children); return true
        }
        if editMovementChildren(in: &children, parent: parent, edit) {
            nodes[index] = .group(id, children); return true
        }
    }
    return false
}
