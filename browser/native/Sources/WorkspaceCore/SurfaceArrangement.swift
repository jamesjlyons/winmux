import Foundation

extension SurfaceTree {
    /// Replace the specified portion of a View with a complete declarative
    /// arrangement. Unmentioned members keep their existing subtrees, including
    /// in the destination; callers cannot create, drop, or duplicate owners.
    @discardableResult
    public mutating func arrange(_ nodes: [SurfaceTreeNode], in workspace: String,
        layouts newLayouts: [UUID: SurfaceContainerLayout] = [:],
        activeSurfaces newSelections: [UUID: SurfaceID] = [:], weights newWeights: [String: Double] = [:]
    ) -> Bool {
        let original = roots.values.flatMap { $0.flatMap(\.surfaces) }
        let members = nodes.flatMap(\.surfaces), included = Set(members)
        guard members.count == included.count, included.isSubset(of: Set(original)) else { return false }
        var candidate = self
        let kept = Set(original).subtracting(included)
        for name in candidate.roots.keys { candidate.roots[name] = candidate.retainingNodes(candidate.roots[name] ?? [], keeping: kept) }
        candidate.roots[workspace] = nodes + (candidate.roots[workspace] ?? [])
        candidate.layouts.merge(newLayouts) { _, new in new }
        candidate.activeSurfaces.merge(newSelections) { _, new in new }
        candidate.weights.merge(newWeights) { _, new in new }
        candidate.pruneMetadata()
        guard let data = try? JSONEncoder().encode(candidate),
              (try? JSONDecoder().decode(Self.self, from: data)) != nil,
              candidate.roots.values.flatMap({ $0.flatMap(\.surfaces) }).count == original.count else { return false }
        self = candidate
        return true
    }
}
