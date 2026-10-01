import Foundation

/// Owner-independent organization. Leaves retain their complete profile/native
/// identity; this tree never transfers WebContents or pretends to own AX windows.
public indirect enum SurfaceTreeNode: Equatable, Sendable {
    case surface(SurfaceID)
    case group(UUID, [SurfaceTreeNode])

    public var surfaces: [SurfaceID] {
        switch self {
        case .surface(let id): [id]
        case .group(_, let children): children.flatMap(\.surfaces)
        }
    }
}

public struct SurfaceTree: Equatable, Sendable {
    public private(set) var roots: [String: [SurfaceTreeNode]] = [:]
    public private(set) var layouts: [UUID: SurfaceContainerLayout] = [:]
    public private(set) var activeSurfaces: [UUID: SurfaceID] = [:]
    public init() {}

    public mutating func select(_ id: SurfaceID) {
        func visit(_ node: SurfaceTreeNode) {
            if case .group(let group, let children) = node, node.surfaces.contains(id) {
                activeSurfaces[group] = id
                children.forEach(visit)
            }
        }
        roots.values.flatMap { $0 }.forEach(visit)
    }

    public func workspace(of id: SurfaceID) -> String? {
        roots.first { $0.value.flatMap(\.surfaces).contains(id) }?.key
    }

    /// Reconcile owner membership without throwing away the user's mixed order.
    /// Callers retain disconnected browser leaves until authoritative removal.
    public mutating func reconcile(_ ids: [SurfaceID], in workspace: String, retaining: Set<SurfaceID> = []) {
        let allowed = Set(ids).union(retaining)
        roots[workspace] = Self.filter(roots[workspace] ?? [], keeping: allowed)
        for id in ids where self.workspace(of: id) != workspace {
            remove(id)
            roots[workspace, default: []].append(.surface(id))
        }
        pruneMetadata()
    }

    public mutating func remove(_ id: SurfaceID) {
        for name in Array(roots.keys) {
            roots[name] = Self.filter(roots[name] ?? [], keeping: Set((roots[name] ?? []).flatMap(\.surfaces)).subtracting([id]))
        }
        pruneMetadata()
    }

    public mutating func mergeWorkspace(_ source: String, into target: String) {
        guard source != target, let nodes = roots.removeValue(forKey: source) else { return }
        roots[target, default: []].append(contentsOf: nodes)
    }

    @discardableResult public mutating func move(_ id: SurfaceID, before target: SurfaceID) -> Bool {
        guard id != target, let name = workspace(of: id), workspace(of: target) == name else { return false }
        var nodes = roots[name] ?? []
        nodes = Self.filter(nodes, keeping: Set(nodes.flatMap(\.surfaces)).subtracting([id]))
        guard Self.insert(.surface(id), before: target, into: &nodes) else { return false }
        roots[name] = nodes
        return true
    }

    @discardableResult public mutating func group(_ id: SurfaceID, with target: SurfaceID, layout: SurfaceContainerLayout = .stack) -> Bool {
        guard id != target, let name = workspace(of: id), workspace(of: target) == name else { return false }
        var nodes = roots[name] ?? []
        nodes = Self.filter(nodes, keeping: Set(nodes.flatMap(\.surfaces)).subtracting([id]))
        let group = UUID()
        guard Self.replace(target, in: &nodes, with: .group(group, [.surface(target), .surface(id)])) else { return false }
        layouts[group] = layout
        activeSurfaces[group] = target
        roots[name] = nodes
        return true
    }

    @discardableResult public mutating func ungroup(_ group: UUID) -> Bool {
        for name in Array(roots.keys) {
            var nodes = roots[name] ?? []
            if Self.ungroup(group, in: &nodes) { roots[name] = nodes; pruneMetadata(); return true }
        }
        return false
    }

    @discardableResult public mutating func moveToRoot(_ id: SurfaceID, in name: String) -> Bool {
        guard workspace(of: id) != nil else { return false }
        remove(id)
        roots[name, default: []].append(.surface(id))
        return true
    }

    @discardableResult public mutating func reorder(_ id: SurfaceID, earlier: Bool) -> Bool {
        guard let name = workspace(of: id) else { return false }
        var nodes = roots[name] ?? []
        guard Self.reorder(id, earlier: earlier, in: &nodes) else { return false }
        roots[name] = nodes
        return true
    }

    private mutating func pruneMetadata() {
        var groups: Set<UUID> = []
        func visit(_ node: SurfaceTreeNode) {
            if case .group(let id, let children) = node { groups.insert(id); children.forEach(visit) }
        }
        roots.values.flatMap { $0 }.forEach(visit)
        layouts = layouts.filter { groups.contains($0.key) }
        activeSurfaces = activeSurfaces.filter { groups.contains($0.key) }
    }

    private static func filter(_ nodes: [SurfaceTreeNode], keeping ids: Set<SurfaceID>) -> [SurfaceTreeNode] {
        nodes.flatMap { node -> [SurfaceTreeNode] in
            switch node {
            case .surface(let id): return ids.contains(id) ? [node] : []
            case .group(let group, let children):
                let remaining = filter(children, keeping: ids)
                return remaining.count > 1 ? [.group(group, remaining)] : remaining
            }
        }
    }

    private static func insert(_ node: SurfaceTreeNode, before target: SurfaceID, into nodes: inout [SurfaceTreeNode]) -> Bool {
        for index in nodes.indices {
            switch nodes[index] {
            case .surface(let id) where id == target: nodes.insert(node, at: index); return true
            case .group(let id, var children):
                if insert(node, before: target, into: &children) { nodes[index] = .group(id, children); return true }
            default: break
            }
        }
        return false
    }

    private static func replace(_ target: SurfaceID, in nodes: inout [SurfaceTreeNode], with replacement: SurfaceTreeNode) -> Bool {
        for index in nodes.indices {
            switch nodes[index] {
            case .surface(let id) where id == target: nodes[index] = replacement; return true
            case .group(let id, var children):
                if replace(target, in: &children, with: replacement) { nodes[index] = .group(id, children); return true }
            default: break
            }
        }
        return false
    }

    private static func ungroup(_ target: UUID, in nodes: inout [SurfaceTreeNode]) -> Bool {
        for index in nodes.indices {
            guard case .group(let id, var children) = nodes[index] else { continue }
            if id == target { nodes.replaceSubrange(index...index, with: children); return true }
            if ungroup(target, in: &children) { nodes[index] = .group(id, children); return true }
        }
        return false
    }

    private static func reorder(_ target: SurfaceID, earlier: Bool, in nodes: inout [SurfaceTreeNode]) -> Bool {
        for index in nodes.indices {
            switch nodes[index] {
            case .surface(let id) where id == target:
                let destination = index + (earlier ? -1 : 1)
                guard nodes.indices.contains(destination) else { return false }
                nodes.swapAt(index, destination); return true
            case .group(let id, var children):
                if reorder(target, earlier: earlier, in: &children) { nodes[index] = .group(id, children); return true }
            default: break
            }
        }
        return false
    }
}
