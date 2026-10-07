import Foundation

/// A leaf or complete arrangement. Owners resolve legacy window/group names at
/// their boundary; structural operations keep these identities throughout.
public enum SurfacePane: Hashable, Sendable {
    case surface(SurfaceID)
    case group(UUID)

    public var weightKey: String {
        switch self {
        case .surface(let id): id.description
        case .group(let id): "group:" + id.uuidString.lowercased()
        }
    }
}

public struct SurfacePaneAllocation: Sendable {
    public let pane: SurfacePane
    public let parent: UUID?
    public let layout: SurfaceContainerLayout
    public let siblings: [SurfaceTreeNode]
    public let ratio: Double
}

extension SurfaceTreeNode {
    public var pane: SurfacePane {
        switch self {
        case .surface(let id): .surface(id)
        case .group(let id, _): .group(id)
        }
    }
}

extension SurfaceTree {
    public func node(for pane: SurfacePane) -> SurfaceTreeNode? {
        switch pane {
        case .surface(let id): workspace(of: id) == nil ? nil : .surface(id)
        case .group(let id): group(id)
        }
    }

    public func workspace(of pane: SurfacePane) -> String? {
        switch pane {
        case .surface(let id): workspace(of: id)
        case .group(let id): workspace(ofGroup: id)
        }
    }

    public func ancestors(of pane: SurfacePane) -> [SurfaceTreeNode] {
        guard let name = workspace(of: pane) else { return [] }
        func find(_ nodes: [SurfaceTreeNode], path: [SurfaceTreeNode]) -> [SurfaceTreeNode]? {
            for node in nodes {
                if node.pane == pane { return path }
                if case .group(_, let children) = node, let found = find(children, path: path + [node]) { return found }
            }
            return nil
        }
        return find(roots[name] ?? [], path: []) ?? []
    }

    public func stack(containing surface: SurfaceID) -> UUID? {
        for node in ancestors(of: .surface(surface)).reversed() {
            if case .group(let id, _) = node, (layouts[id] ?? .stack) == .stack { return id }
        }
        return nil
    }

    /// The nearest split that allocates this pane on the requested axis. A
    /// member of a stack sizes the stack as a unit; root siblings are horizontal.
    public func allocation(of pane: SurfacePane, axis: SurfaceContainerLayout? = nil) -> SurfacePaneAllocation? {
        guard axis != .stack, let name = workspace(of: pane), let node = node(for: pane) else { return nil }
        let path = ancestors(of: pane) + [node]
        for index in path.indices.reversed() {
            let parent: UUID?, layout: SurfaceContainerLayout, siblings: [SurfaceTreeNode]
            if index > 0, case .group(let id, let children) = path[index - 1] {
                parent = id; layout = layouts[id] ?? .stack; siblings = children
            } else {
                parent = nil; layout = .horizontal; siblings = roots[name] ?? []
            }
            guard layout != .stack, axis == nil || layout == axis, siblings.count > 1 else { continue }
            let existing = siblings.compactMap { weights[$0.weightKey] }
            let fallback = existing.isEmpty ? 1 : existing.reduce(0, +) / Double(existing.count)
            let total = siblings.reduce(0) { $0 + (weights[$1.weightKey] ?? fallback) }
            return .init(pane: path[index].pane, parent: parent, layout: layout, siblings: siblings,
                         ratio: (weights[path[index].weightKey] ?? fallback) / total)
        }
        return nil
    }

    @discardableResult
    public mutating func setProportion(_ ratio: Double, of pane: SurfacePane, axis: SurfaceContainerLayout? = nil) -> Bool {
        guard ratio.isFinite, ratio > 0, ratio <= 1, let allocation = allocation(of: pane, axis: axis) else { return false }
        let siblings = allocation.siblings
        let existing = siblings.compactMap { weights[$0.weightKey] }
        let fallback = existing.isEmpty ? 1 : existing.reduce(0, +) / Double(existing.count)
        let others = siblings.filter { $0.pane != allocation.pane }
        let remaining = others.reduce(0) { $0 + (weights[$1.weightKey] ?? fallback) }
        for sibling in siblings {
            let share = sibling.pane == allocation.pane ? ratio
                : (1 - ratio) * (weights[sibling.weightKey] ?? fallback) / remaining
            // Keep representable positive allocations. Owner minimums are still
            // enforced by placement, including a requested 100% allocation.
            weights[sibling.weightKey] = max(1, min(30000, share * 30000))
        }
        return true
    }

    /// Swap complete subtrees and the allocation of their old positions. Reject
    /// overlapping targets before editing; ancestors keep valid selections.
    @discardableResult
    public mutating func swap(_ first: SurfacePane, _ second: SurfacePane) -> Bool {
        guard first != second, let a = node(for: first), let b = node(for: second),
              Set(a.surfaces).isDisjoint(with: b.surfaces) else { return false }
        var candidate = self
        func visit(_ node: SurfaceTreeNode) -> SurfaceTreeNode {
            if node.pane == first { return b }
            if node.pane == second { return a }
            if case .group(let id, let children) = node { return .group(id, children.map(visit)) }
            return node
        }
        for name in candidate.roots.keys { candidate.roots[name] = candidate.roots[name]?.map(visit) }
        candidate.weights[first.weightKey] = weights[second.weightKey]
        candidate.weights[second.weightKey] = weights[first.weightKey]
        func selected(in node: SurfaceTreeNode) -> SurfaceID? {
            if case .group(let id, _) = node, let active = activeSurfaces[id], node.surfaces.contains(active) { return active }
            return node.surfaces.first
        }
        for (group, active) in activeSurfaces where candidate.group(group)?.surfaces.contains(active) == false {
            if a.surfaces.contains(active) { candidate.activeSurfaces[group] = selected(in: b) }
            else if b.surfaces.contains(active) { candidate.activeSurfaces[group] = selected(in: a) }
        }
        return finishPaneEdit(candidate)
    }

    /// Place one leaf or arrangement beside another. Match the nearest split's
    /// axis when possible, otherwise introduce one explicit split at the target.
    @discardableResult
    public mutating func place(_ source: SurfacePane, beside target: SurfacePane, toward direction: SurfaceDirection) -> Bool {
        guard source != target, let moving = node(for: source), let originalTarget = node(for: target),
              Set(moving.surfaces).isDisjoint(with: originalTarget.surfaces),
              let destination = workspace(of: target) else { return false }
        var candidate = self
        let kept = Set(candidate.roots.values.flatMap { $0.flatMap(\.surfaces) }).subtracting(moving.surfaces)
        for name in candidate.roots.keys { candidate.roots[name] = candidate.retainingNodes(candidate.roots[name] ?? [], keeping: kept) }
        let axis: SurfaceContainerLayout = direction.isHorizontal ? .horizontal : .vertical
        let targetPane: SurfacePane
        if case .surface(let leaf) = target, let stack = candidate.stack(containing: leaf) {
            targetPane = .group(stack)
        } else { targetPane = target }
        guard let anchor = candidate.node(for: targetPane) else { return false }
        let path = candidate.ancestors(of: targetPane) + [anchor]
        var insertion: (parent: SurfacePane?, anchor: SurfacePane)?
        for index in path.indices.reversed() {
            if index == 0 {
                if axis == .horizontal { insertion = (nil, path[index].pane) }
            } else if case .group(let id, _) = path[index - 1], candidate.layouts[id] == axis {
                insertion = (.group(id), path[index].pane)
            }
            if insertion != nil { break }
        }
        if let insertion {
            func insert(_ nodes: inout [SurfaceTreeNode], parent: SurfacePane?) -> Bool {
                if parent == insertion.parent, let index = nodes.firstIndex(where: { $0.pane == insertion.anchor }) {
                    nodes.insert(moving, at: index + (direction.isPositive ? 1 : 0)); return true
                }
                for index in nodes.indices {
                    if case .group(let id, var children) = nodes[index], insert(&children, parent: .group(id)) {
                        nodes[index] = .group(id, children); return true
                    }
                }
                return false
            }
            var roots = candidate.roots[destination] ?? []
            guard insert(&roots, parent: nil) else { return false }
            candidate.roots[destination] = roots
        } else {
            let id = UUID()
            let replacement = SurfaceTreeNode.group(id, direction.isPositive ? [anchor, moving] : [moving, anchor])
            func wrap(_ node: SurfaceTreeNode) -> SurfaceTreeNode {
                if node.pane == targetPane { return replacement }
                if case .group(let group, let children) = node { return .group(group, children.map(wrap)) }
                return node
            }
            candidate.roots[destination] = candidate.roots[destination]?.map(wrap)
            candidate.layouts[id] = axis
            candidate.weights[replacement.weightKey] = candidate.weights[anchor.weightKey]
            candidate.weights[anchor.weightKey] = 1
            candidate.weights[moving.weightKey] = 1
        }
        return finishPaneEdit(candidate)
    }

    private mutating func finishPaneEdit(_ proposed: SurfaceTree) -> Bool {
        var candidate = proposed
        candidate.pruneMetadata()
        guard let data = try? JSONEncoder().encode(candidate),
              (try? JSONDecoder().decode(Self.self, from: data)) != nil else { return false }
        self = candidate
        return true
    }
}
