import Foundation

/// A saved arrangement references pin IDs, so closing/reopening a member can
/// replace its live surface without losing the user's split sizes or stack.
public struct PinnedViewGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var template: SurfaceTree
    public var members: [SurfaceID: UUID]

    public init(id: UUID, title: String, template: SurfaceTree, members: [SurfaceID: UUID]) {
        self.id = id; self.title = title; self.template = template; self.members = members
    }

    public func isValid(in workspace: String) -> Bool {
        guard title.utf8.count <= 4096, members.count >= 2, members.count <= 10000,
              Set(members.values).count == members.count,
              template.roots.count == 1, template.roots[workspace]?.count == 1,
              let group = template.group(id), template.roots[workspace]?.first == group else { return false }
        return Set(group.surfaces) == Set(members.keys)
    }

    public func layout(using surfaces: [UUID: SurfaceID], in workspace: String) -> SurfaceTree {
        var result = template
        for (old, pin) in members {
            if let current = surfaces[pin] {
                if current != old { _ = result.replaceSurface(old, with: current) }
            } else { result.remove(old) }
        }
        if let source = result.roots.keys.first, source != workspace {
            if result.group(id) != nil { _ = result.moveGroupToRoot(id, in: workspace) }
            else { for surface in (result.roots[source] ?? []).flatMap(\.surfaces) { _ = result.moveToRoot(surface, in: workspace) } }
            result.removeWorkspace(source)
        }
        return result
    }
}
