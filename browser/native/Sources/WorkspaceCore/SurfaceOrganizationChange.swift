import Foundation

/// The core produces membership effects together with the validated layout.
/// Adapters execute these effects only after checking the current live owners.
public struct SurfaceMembershipChange: Equatable, Sendable {
    public let surfaceID: SurfaceID
    public let source: String
    public let destination: String
}

public struct SurfaceOrganizationChange: Equatable, Sendable {
    public let tree: SurfaceTree
    public let workspaces: Set<String>
    public let membership: [SurfaceMembershipChange]
}

extension SurfaceTree {
    /// Prepare an atomic structural edit without changing observations or live
    /// owners. Organization cannot create/close surfaces, move reservations, or
    /// alter a workspace outside the preflighted set.
    public func preparingOrganizationChange(in workspaces: Set<String>,
        reserving reservations: [SurfaceID: String] = [:], selected: SurfaceID? = nil,
        _ edit: (inout SurfaceTree) -> Bool
    ) -> SurfaceOrganizationChange? {
        var candidate = self
        guard edit(&candidate),
              reservations.allSatisfy({ candidate.workspace(of: $0.key) == $0.value }),
              let data = try? JSONEncoder().encode(candidate),
              (try? JSONDecoder().decode(SurfaceTree.self, from: data)) != nil else { return nil }

        let before = membershipBySurface, after = candidate.membershipBySurface
        guard Set(before.keys) == Set(after.keys) else { return nil }
        for name in Set(roots.keys).union(candidate.roots.keys).subtracting(workspaces) {
            guard roots[name] == candidate.roots[name],
                  (roots[name] ?? []).allSatisfy({ unchangedMetadata(for: $0, in: candidate) }) else { return nil }
        }
        let membership = before.keys.sorted { $0.description < $1.description }.compactMap { id -> SurfaceMembershipChange? in
            guard let source = before[id], let destination = after[id], source != destination else { return nil }
            return .init(surfaceID: id, source: source, destination: destination)
        }
        guard membership.allSatisfy({ workspaces.contains($0.source) && workspaces.contains($0.destination) }) else { return nil }
        if let selected, candidate.workspace(of: selected).map(workspaces.contains) == true { candidate.select(selected) }
        return .init(tree: candidate, workspaces: workspaces, membership: membership)
    }

    private var membershipBySurface: [SurfaceID: String] {
        roots.reduce(into: [:]) { result, entry in
            for surface in entry.value.flatMap(\.surfaces) { result[surface] = entry.key }
        }
    }

    private func unchangedMetadata(for node: SurfaceTreeNode, in candidate: SurfaceTree) -> Bool {
        guard weights[node.weightKey] == candidate.weights[node.weightKey] else { return false }
        guard case .group(let id, let children) = node else { return true }
        return layouts[id] == candidate.layouts[id] && activeSurfaces[id] == candidate.activeSurfaces[id] &&
            children.allSatisfy { unchangedMetadata(for: $0, in: candidate) }
    }
}
