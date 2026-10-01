import Foundation

public enum SurfaceSnapshotError: Error { case invalidTree }

/// Workspace references only: never page content, titles, URLs or runtime hosts.
/// A snapshot cannot create browser tabs; live membership remains owner-owned.
public struct SurfaceWorkspaceSnapshot: Codable, Equatable, Sendable {
    public var tree: SurfaceTree
    public var layoutWorkspaces: Set<String>
    public var selected: SurfaceID?
    public var closedBrowserTabs: Set<SurfaceID>

    public init(tree: SurfaceTree, layoutWorkspaces: Set<String>, selected: SurfaceID?, closedBrowserTabs: Set<SurfaceID>) {
        self.tree = tree; self.layoutWorkspaces = layoutWorkspaces
        self.selected = selected; self.closedBrowserTabs = closedBrowserTabs
    }

    public func validated() throws -> Self {
        guard layoutWorkspaces.isSubset(of: Set(tree.roots.keys)), closedBrowserTabs.count <= 10000,
              closedBrowserTabs.allSatisfy({ if case .browserTab = $0 { return true }; return false }),
              selected.map({ tree.workspace(of: $0) != nil }) ?? true,
              Set(tree.roots.values.flatMap { $0.flatMap(\.surfaces) }).isDisjoint(with: closedBrowserTabs)
        else { throw SurfaceSnapshotError.invalidTree }
        return self
    }
}

extension SurfaceTree {
    /// Ordered leaves in the nearest stack. Split siblings stay independent panes.
    public func stackItems(containing target: SurfaceID) -> [SurfaceID]? {
        func find(_ nodes: [SurfaceTreeNode]) -> [SurfaceID]? {
            for node in nodes {
                guard case .group(let id, let children) = node, node.surfaces.contains(target) else { continue }
                if let nested = find(children) { return nested }
                if (layouts[id] ?? .stack) == .stack { return children.flatMap(\.surfaces) }
            }
            return nil
        }
        return find(roots.values.flatMap { $0 })
    }
}
