import Foundation

/// Launch descriptors use member IDs; live SurfaceIDs may change after closing.
public indirect enum PinnedLayoutNode: Codable, Equatable, Sendable {
    case member(UUID, Double)
    case group(UUID, SurfaceContainerLayout, [PinnedLayoutNode], UUID?, Double)

    public var members: [UUID] {
        switch self {
        case .member(let id, _): [id]
        case .group(_, _, let children, _, _): children.flatMap(\.members)
        }
    }

    /// Update the surviving layout metadata without deleting closed slots.
    public func refreshing(from tree: SurfaceTree, bindings: [UUID: SurfaceID]) -> Self {
        switch self {
        case .member(let id, let weight):
            return .member(id, bindings[id].flatMap { tree.weights[SurfaceTreeNode.surface($0).weightKey] } ?? weight)
        case .group(let id, let layout, let children, let active, let weight):
            let selected = tree.activeSurfaces[id].flatMap { surface in bindings.first { $0.value == surface }?.key } ?? active
            return .group(id, tree.layouts[id] ?? layout, children.map { $0.refreshing(from: tree, bindings: bindings) },
                          selected, tree.weights[SurfaceTreeNode.group(id, []).weightKey] ?? weight)
        }
    }

    func validate(depth: Int, groups: inout Set<UUID>) -> Bool {
        guard depth <= 32 else { return false }
        switch self {
        case .member(_, let weight): return weight.isFinite && (1...30000).contains(weight)
        case .group(let id, _, let children, let active, let weight):
            guard groups.insert(id).inserted, !children.isEmpty, children.count <= 10000,
                  groups.count <= 10000, weight.isFinite && (1...30000).contains(weight),
                  active.map({ members.contains($0) }) ?? true else { return false }
            return children.allSatisfy { $0.validate(depth: depth + 1, groups: &groups) }
        }
    }

    public func keeping(_ ids: Set<UUID>) -> Self? {
        switch self {
        case .member(let id, _): return ids.contains(id) ? self : nil
        case .group(let id, let layout, let children, let active, let weight):
            let retained = children.compactMap { $0.keeping(ids) }
            guard !retained.isEmpty else { return nil }
            return .group(id, layout, retained, active.flatMap { ids.contains($0) ? $0 : nil }, weight)
        }
    }

    public static func capture(_ node: SurfaceTreeNode, tree: SurfaceTree, members: [SurfaceID: UUID]) -> Self? {
        switch node {
        case .surface(let id):
            return members[id].map { .member($0, tree.weights[node.weightKey] ?? 1) }
        case .group(let id, let children):
            let saved = children.compactMap { capture($0, tree: tree, members: members) }
            guard !saved.isEmpty else { return nil }
            return .group(id, tree.layouts[id] ?? .stack, saved,
                          tree.activeSurfaces[id].flatMap { members[$0] }, tree.weights[node.weightKey] ?? 1)
        }
    }

    public func project(bindings: [UUID: SurfaceID], tree: inout SurfaceTree) -> SurfaceTreeNode? {
        switch self {
        case .member(let id, let weight):
            guard let surface = bindings[id] else { return nil }
            let node = SurfaceTreeNode.surface(surface)
            tree.weights[node.weightKey] = weight
            return node
        case .group(let id, let layout, let children, let active, let weight):
            let live = children.compactMap { $0.project(bindings: bindings, tree: &tree) }
            guard live.count > 1 else { return live.first }
            let node = SurfaceTreeNode.group(id, live)
            tree.layouts[id] = layout
            tree.weights[node.weightKey] = weight
            if let selected = active.flatMap({ bindings[$0] }), node.surfaces.contains(selected) {
                tree.activeSurfaces[id] = selected
            }
            return node
        }
    }
}

public struct PinnedDesktop: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case app, tab, group }
    public var id: UUID
    public var spaceID: String
    public var workspaceName: String
    public var title: String
    public var kind: Kind
    public var memberIDs: [UUID]
    public var layout: [PinnedLayoutNode]
    public var selectedMember: UUID?
    public var formerRegularIndex: Int?

    public init(id: UUID = UUID(), spaceID: String, workspaceName: String, title: String,
                kind: Kind, memberIDs: [UUID], layout: [PinnedLayoutNode] = [],
                selectedMember: UUID? = nil, formerRegularIndex: Int? = nil) {
        self.id = id; self.spaceID = spaceID; self.workspaceName = workspaceName
        self.title = title; self.kind = kind; self.memberIDs = memberIDs; self.layout = layout
        self.selectedMember = selectedMember; self.formerRegularIndex = formerRegularIndex
    }

    public var isValid: Bool {
        var groups = Set<UUID>()
        guard layout.allSatisfy({ $0.validate(depth: 0, groups: &groups) }) else { return false }
        return (formerRegularIndex.map { $0 >= 0 } ?? true) && !spaceID.isEmpty && spaceID.utf8.count <= 1024 && !workspaceName.isEmpty && workspaceName.utf8.count <= 1024 &&
        title.utf8.count <= 4096 && !memberIDs.isEmpty && memberIDs.count <= 10000 &&
        Set(memberIDs).count == memberIDs.count &&
        Set(layout.flatMap(\.members)).isSubset(of: Set(memberIDs)) &&
        Set(layout.flatMap(\.members)).count == layout.flatMap(\.members).count &&
        (selectedMember.map(memberIDs.contains) ?? true)
    }
}

public struct SpacePinShelf: Codable, Equatable, Sendable {
    public var spaceID: String
    public var desktopOrder: [UUID]
    public var lastRegularWorkspaceName: String?
    public init(spaceID: String, desktopOrder: [UUID] = [], lastRegularWorkspaceName: String? = nil) {
        self.spaceID = spaceID; self.desktopOrder = desktopOrder; self.lastRegularWorkspaceName = lastRegularWorkspaceName
    }
}
