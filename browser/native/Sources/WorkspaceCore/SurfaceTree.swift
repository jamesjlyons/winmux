import Foundation

/// Owner-independent organization. Leaves retain their complete profile/native
/// identity; this tree never transfers WebContents or pretends to own AX windows.
public indirect enum SurfaceTreeNode: Equatable, Codable, Sendable {
    case surface(SurfaceID)
    case group(UUID, [SurfaceTreeNode])

    enum CodingKeys: String, CodingKey { case surface, group, children }
    public init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= 96 else { throw SurfaceSnapshotError.invalidTree }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(SurfaceID.self, forKey: .surface) {
            guard !c.contains(.group), !c.contains(.children) else { throw SurfaceSnapshotError.invalidTree }
            self = .surface(id)
        } else {
            self = .group(try c.decode(UUID.self, forKey: .group), try c.decode([Self].self, forKey: .children))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .surface(let id): try c.encode(id, forKey: .surface)
        case .group(let id, let children): try c.encode(id, forKey: .group); try c.encode(children, forKey: .children)
        }
    }

    public var surfaces: [SurfaceID] {
        switch self {
        case .surface(let id): [id]
        case .group(_, let children): children.flatMap(\.surfaces)
        }
    }
}

public struct SurfaceTree: Equatable, Codable, Sendable {
    public private(set) var roots: [String: [SurfaceTreeNode]] = [:]
    public private(set) var layouts: [UUID: SurfaceContainerLayout] = [:]
    public private(set) var activeSurfaces: [UUID: SurfaceID] = [:]
    public private(set) var weights: [String: Double] = [:]
    public init() {}

    enum CodingKeys: String, CodingKey { case roots, layouts, activeSurfaces, weights }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roots = try c.decode([String: [SurfaceTreeNode]].self, forKey: .roots)
        layouts = try c.decode([UUID: SurfaceContainerLayout].self, forKey: .layouts)
        activeSurfaces = try c.decode([UUID: SurfaceID].self, forKey: .activeSurfaces)
        weights = try c.decodeIfPresent([String: Double].self, forKey: .weights) ?? [:]
        guard weights.count <= 20000, weights.values.allSatisfy({ $0.isFinite && (1...30000).contains($0) }) else { throw SurfaceSnapshotError.invalidTree }
        guard roots.count <= 1024, roots.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }) else { throw SurfaceSnapshotError.invalidTree }
        var surfaces: Set<SurfaceID> = [], groups: Set<UUID> = []
        func validate(_ nodes: [SurfaceTreeNode], depth: Int) throws {
            guard depth <= 32 else { throw SurfaceSnapshotError.invalidTree }
            for node in nodes {
                switch node {
                case .surface(let id):
                    guard surfaces.insert(id).inserted, surfaces.count <= 10000 else { throw SurfaceSnapshotError.invalidTree }
                case .group(let id, let children):
                    guard groups.insert(id).inserted, groups.count <= 10000, children.count >= 2,
                          activeSurfaces[id].map({ node.surfaces.contains($0) }) ?? true else { throw SurfaceSnapshotError.invalidTree }
                    try validate(children, depth: depth + 1)
                }
            }
        }
        try validate(roots.values.flatMap { $0 }, depth: 0)
        let weightKeys = Set(roots.values.flatMap { $0 }.flatMap(\.allWeightKeys))
        guard Set(weights.keys).isSubset(of: weightKeys) else { throw SurfaceSnapshotError.invalidTree }
        guard Set(layouts.keys).isSubset(of: groups), Set(activeSurfaces.keys).isSubset(of: groups) else { throw SurfaceSnapshotError.invalidTree }
    }

    public mutating func setWeights(_ values: [String: Double]) {
        let keys = Set(roots.values.flatMap { $0 }.flatMap(\.allWeightKeys))
        for (key, value) in values where keys.contains(key) && value.isFinite && (1...30000).contains(value) {
            weights[key] = value
        }
    }

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

    public func group(_ target: UUID) -> SurfaceTreeNode? {
        func find(_ nodes: [SurfaceTreeNode]) -> SurfaceTreeNode? {
            for node in nodes {
                guard case .group(let id, let children) = node else { continue }
                if id == target { return node }
                if let nested = find(children) { return nested }
            }
            return nil
        }
        return find(roots.values.flatMap { $0 })
    }

    public func workspace(ofGroup target: UUID) -> String? {
        guard let member = group(target)?.surfaces.first else { return nil }
        return workspace(of: member)
    }

    /// Transfer one complete subtree without pruning its identity or metadata
    /// between removing it from the source and inserting it at the destination.
    @discardableResult public mutating func moveGroupToRoot(_ target: UUID, in destination: String) -> Bool {
        guard !destination.isEmpty, destination.utf8.count <= 4096,
              let source = workspace(ofGroup: target), source != destination,
              let subtree = group(target) else { return false }
        func removing(_ nodes: [SurfaceTreeNode]) -> [SurfaceTreeNode] {
            nodes.flatMap { node -> [SurfaceTreeNode] in
                guard case .group(let id, let children) = node else { return [node] }
                if id == target { return [] }
                let remaining = removing(children)
                return remaining.count > 1 ? [.group(id, remaining)] : remaining
            }
        }
        var candidate = self
        candidate.roots[source] = removing(roots[source] ?? [])
        candidate.roots[destination, default: []].append(subtree)
        candidate.pruneMetadata()
        guard candidate.isValidOrganization else { return false }
        self = candidate
        return true
    }

    /// Initial native adoption retains nested splits and stacks. Existing mixed
    /// organization is never overwritten by a later native sidebar refresh.
    @discardableResult public mutating func importOrganization(
        _ nodes: [SurfaceTreeNode], in workspace: String,
        layouts importedLayouts: [UUID: SurfaceContainerLayout],
        activeSurfaces importedActive: [UUID: SurfaceID], weights importedWeights: [String: Double]
    ) -> Bool {
        let ids = nodes.flatMap(\.surfaces)
        guard !ids.isEmpty, Set(ids).count == ids.count, let existing = roots[workspace],
              ids.allSatisfy({ existing.contains(.surface($0)) }) else { return false }
        let imported = Set(ids)
        var candidate = self
        candidate.roots[workspace] = nodes + existing.filter {
            if case .surface(let id) = $0 { return !imported.contains(id) }
            return true
        }
        candidate.layouts.merge(importedLayouts) { _, imported in imported }
        candidate.activeSurfaces.merge(importedActive) { _, imported in imported }
        candidate.weights.merge(importedWeights) { _, imported in imported }
        candidate.pruneMetadata()
        guard candidate.isValidOrganization else { return false }
        self = candidate
        return true
    }

    private var isValidOrganization: Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        return (try? JSONDecoder().decode(Self.self, from: data)) != nil
    }

    public func containingGroup(of target: SurfaceID) -> UUID? {
        func find(_ nodes: [SurfaceTreeNode]) -> UUID? {
            for node in nodes {
                if case .group(let id, let children) = node, node.surfaces.contains(target) {
                    return find(children) ?? id
                }
            }
            return nil
        }
        return find(roots.values.flatMap { $0 })
    }

    /// Change the nearest container, keeping its identity and member order.
    /// Root leaves use one new explicit group so the layout persists normally.
    @discardableResult public mutating func setLayout(containing target: SurfaceID, to layout: SurfaceContainerLayout) -> Bool {
        guard let workspace = workspace(of: target) else { return false }
        if let group = containingGroup(of: target) { layouts[group] = layout; return true }
        guard let nodes = roots[workspace], nodes.count > 1 else { return false }
        let group = UUID()
        roots[workspace] = [.group(group, nodes)]
        layouts[group] = layout
        activeSurfaces[group] = target
        return true
    }

    public mutating func importStack(_ ids: [SurfaceID], in workspace: String) {
        guard ids.count > 1, Set(ids).count == ids.count, let nodes = roots[workspace],
              ids.allSatisfy({ id in nodes.contains(.surface(id)) }),
              let index = nodes.firstIndex(of: .surface(ids[0])) else { return }
        let group = UUID()
        roots[workspace] = nodes.enumerated().compactMap { offset, node in
            if offset == index { return .group(group, ids.map(SurfaceTreeNode.surface)) }
            if case .surface(let id) = node, ids.contains(id) { return nil }
            return node
        }
        layouts[group] = .stack
        activeSurfaces[group] = ids[0]
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
        pruneMetadata()
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
        pruneMetadata()
        return true
    }

    /// Append to the nearest existing stack, retaining its identity and other
    /// tabs. A drop within that stack selects the dragged tab without nesting it.
    @discardableResult public mutating func insertIntoStack(_ id: SurfaceID, with target: SurfaceID) -> Bool {
        guard id != target, let name = workspace(of: id), workspace(of: target) == name else { return false }
        guard let stack = nearestStack(containing: target, in: roots[name] ?? []) else {
            guard group(id, with: target, layout: .stack) else { return false }
            select(id)
            return true
        }
        func removingSource(_ nodes: [SurfaceTreeNode]) -> [SurfaceTreeNode] {
            nodes.flatMap { node -> [SurfaceTreeNode] in
                switch node {
                case .surface(let leaf): return leaf == id ? [] : [node]
                case .group(let group, let children):
                    let remaining = removingSource(children)
                    return group == stack || remaining.count > 1 ? [.group(group, remaining)] : remaining
                }
            }
        }
        func append(to nodes: inout [SurfaceTreeNode]) -> Bool {
            for index in nodes.indices {
                guard case .group(let group, var children) = nodes[index] else { continue }
                if group == stack {
                    children.append(.surface(id)); nodes[index] = .group(group, children); return true
                }
                if append(to: &children) { nodes[index] = .group(group, children); return true }
            }
            return false
        }
        var nodes = removingSource(roots[name] ?? [])
        guard append(to: &nodes) else { return false }
        roots[name] = nodes
        pruneMetadata()
        select(id)
        return true
    }

    /// Split beside the target's stack as a whole, rather than placing a split
    /// inside one hidden tab. Moving a tab out collapses its old empty container.
    @discardableResult public mutating func split(_ id: SurfaceID, beside target: SurfaceID,
                                                  layout: SurfaceContainerLayout, before: Bool) -> Bool {
        guard layout != .stack, id != target, let name = workspace(of: id), workspace(of: target) == name else { return false }
        var nodes = Self.filter(roots[name] ?? [], keeping: Set((roots[name] ?? []).flatMap(\.surfaces)).subtracting([id]))
        let stack = nearestStack(containing: target, in: nodes)
        let group = UUID()
        var anchorKey: String?
        func wrap(in nodes: inout [SurfaceTreeNode]) -> Bool {
            for index in nodes.indices {
                let node = nodes[index]
                let isAnchor: Bool
                switch node {
                case .surface(let leaf): isAnchor = stack == nil && leaf == target
                case .group(let existing, _): isAnchor = existing == stack
                }
                if isAnchor {
                    anchorKey = node.weightKey
                    nodes[index] = .group(group, before ? [.surface(id), node] : [node, .surface(id)])
                    return true
                }
                if case .group(let existing, var children) = node, wrap(in: &children) {
                    nodes[index] = .group(existing, children); return true
                }
            }
            return false
        }
        guard wrap(in: &nodes), let anchorKey else { return false }
        roots[name] = nodes
        layouts[group] = layout
        activeSurfaces[group] = id
        // Preserve the outer allocation and divide the new pair evenly. Old
        // per-leaf resize weights must not skew a newly created split.
        weights["group:" + group.uuidString.lowercased()] = weights[anchorKey]
        weights[anchorKey] = 1
        weights[id.description] = 1
        pruneMetadata()
        select(id)
        return true
    }

    /// Exchange leaf positions and their allocation weights without changing
    /// surrounding containers or confusing profile-qualified browser IDs.
    @discardableResult public mutating func swapLeaves(_ first: SurfaceID, _ second: SurfaceID) -> Bool {
        guard first != second, let name = workspace(of: first), workspace(of: second) == name else { return false }
        func swapped(_ id: SurfaceID) -> SurfaceID { id == first ? second : id == second ? first : id }
        func visit(_ node: SurfaceTreeNode) -> SurfaceTreeNode {
            switch node {
            case .surface(let id): .surface(swapped(id))
            case .group(let group, let children): .group(group, children.map(visit))
            }
        }
        roots[name] = roots[name]?.map(visit)
        for (group, active) in activeSurfaces { activeSurfaces[group] = swapped(active) }
        let firstWeight = weights[first.description]
        weights[first.description] = weights[second.description]
        weights[second.description] = firstWeight
        return true
    }

    private func nearestStack(containing target: SurfaceID, in nodes: [SurfaceTreeNode]) -> UUID? {
        for node in nodes {
            guard case .group(let group, let children) = node, node.surfaces.contains(target) else { continue }
            if let nested = nearestStack(containing: target, in: children) { return nested }
            if (layouts[group] ?? .stack) == .stack { return group }
        }
        return nil
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
        var groups: [UUID: Set<SurfaceID>] = [:]
        func visit(_ node: SurfaceTreeNode) {
            if case .group(let id, let children) = node { groups[id] = Set(node.surfaces); children.forEach(visit) }
        }
        roots.values.flatMap { $0 }.forEach(visit)
        layouts = layouts.filter { groups[$0.key] != nil }
        activeSurfaces = activeSurfaces.filter { groups[$0.key]?.contains($0.value) == true }
        let keys = Set(roots.values.flatMap { $0 }.flatMap(\.allWeightKeys))
        weights = weights.filter { keys.contains($0.key) }
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


extension SurfaceTreeNode {
    var weightKey: String {
        switch self {
        case .surface(let id): id.description
        case .group(let id, _): "group:" + id.uuidString.lowercased()
        }
    }
    var allWeightKeys: [String] {
        switch self {
        case .surface: [weightKey]
        case .group(_, let children): [weightKey] + children.flatMap(\.allWeightKeys)
        }
    }
}
