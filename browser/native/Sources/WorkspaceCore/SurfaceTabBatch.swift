import Foundation

extension SurfaceTree {
    /// Extract exactly the selected panes in display order. Unselected siblings
    /// remain in place; selected nested arrangements retain their metadata.
    @discardableResult
    public mutating func arrangeTabs(_ panes: [SurfacePane], in destination: String,
                                    grouping layout: SurfaceContainerLayout? = nil) -> Bool {
        guard !panes.isEmpty, Set(panes).count == panes.count, !destination.isEmpty,
              destination.utf8.count <= 4096, layout == nil || panes.count > 1 else { return false }
        let nodes = panes.compactMap { node(for: $0) }
        let members = nodes.flatMap(\.surfaces)
        guard nodes.count == panes.count, Set(members).count == members.count else { return false }
        var candidate = self
        let moving = Set(members)
        let sources = Set(panes.compactMap { workspace(of: $0) })
        for source in sources {
            let original = candidate.roots[source] ?? []
            candidate.roots[source] = candidate.retainingNodes(original, keeping: Set(original.flatMap(\.surfaces)).subtracting(moving))
        }
        if let layout {
            let group = UUID()
            candidate.roots[destination, default: []].append(.group(group, nodes))
            candidate.layouts[group] = layout
            candidate.activeSurfaces[group] = nodes.first?.surfaces.first
        } else {
            candidate.roots[destination, default: []].append(contentsOf: nodes)
        }
        candidate.pruneMetadata()
        guard candidate.isValidOrganization else { return false }
        self = candidate
        return true
    }
}
