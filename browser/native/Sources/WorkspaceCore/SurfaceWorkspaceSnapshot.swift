import Foundation

public enum SurfaceSnapshotError: Error { case invalidTree }

/// Ordinary workspace membership stores references only. Explicit sidebar pins
/// also store the user-selected page title and URL so a closed pin can reopen.
/// Restoration never creates browser tabs; live membership remains owner-owned.
public struct SurfaceWorkspaceSnapshot: Codable, Equatable, Sendable {
    public var tree: SurfaceTree
    public var layoutWorkspaces: Set<String>
    public var selected: SurfaceID?
    public var closedBrowserTabs: Set<SurfaceID>

    public var browserPins: [BrowserSidebarPin]
    public var appPins: [NativeAppSidebarPin]
    public var pinnedGroups: [SpacePinnedGroup]

    public init(tree: SurfaceTree, layoutWorkspaces: Set<String>, selected: SurfaceID?, closedBrowserTabs: Set<SurfaceID>,
                browserPins: [BrowserSidebarPin] = [], appPins: [NativeAppSidebarPin] = [], pinnedGroups: [SpacePinnedGroup] = []) {
        self.tree = tree; self.layoutWorkspaces = layoutWorkspaces
        self.selected = selected; self.closedBrowserTabs = closedBrowserTabs
        self.browserPins = browserPins; self.appPins = appPins; self.pinnedGroups = pinnedGroups
    }

    private enum CodingKeys: String, CodingKey { case tree, layoutWorkspaces, selected, closedBrowserTabs, browserPins, appPins, pinnedGroups }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tree: try values.decode(SurfaceTree.self, forKey: .tree),
                  layoutWorkspaces: try values.decode(Set<String>.self, forKey: .layoutWorkspaces),
                  selected: try values.decodeIfPresent(SurfaceID.self, forKey: .selected),
                  closedBrowserTabs: try values.decode(Set<SurfaceID>.self, forKey: .closedBrowserTabs),
                  browserPins: try values.decodeIfPresent([BrowserSidebarPin].self, forKey: .browserPins) ?? [],
                  appPins: try values.decodeIfPresent([NativeAppSidebarPin].self, forKey: .appPins) ?? [],
                  pinnedGroups: try values.decodeIfPresent([SpacePinnedGroup].self, forKey: .pinnedGroups) ?? [])
    }

    public func validated() throws -> Self {
        let pinnedSurfaces = browserPins.compactMap(\.surfaceID) + appPins.compactMap(\.surfaceID)
        let pinIDs = browserPins.map(\.id) + appPins.map(\.id)
        guard pinIDs.count <= 10000, Set(pinIDs).count == pinIDs.count, browserPins.allSatisfy(\.isValid),
              appPins.allSatisfy(\.isValid), pinnedGroups.allSatisfy(\.isValid),
              Dictionary(grouping: appPins, by: \.workspaceName).values.allSatisfy({ pins in
                  Set(pins.map(\.bundleIdentifier)).count == pins.count
              }),
              Set(pinnedGroups.map(\.spaceID)).count == pinnedGroups.count,
              Set(pinnedGroups.map(\.workspaceName)).count == pinnedGroups.count,
              appPins.allSatisfy({ pin in pinnedGroups.contains { $0.workspaceName == pin.workspaceName } }),
              Set(browserPins.map(\.id)).count == browserPins.count,
              Set(pinnedSurfaces).count == pinnedSurfaces.count,
              Set(pinnedSurfaces).isDisjoint(with: closedBrowserTabs),
              (browserPins.map { ($0.surfaceID, $0.workspaceName) } + appPins.map { ($0.surfaceID, $0.workspaceName) }).allSatisfy({ surface, workspace in
                  surface.flatMap { tree.workspace(of: $0) }.map { $0 == workspace } ?? true
              }),
              pinnedGroups.allSatisfy({ group in
                  group.pinOrder.allSatisfy { id in
                      browserPins.contains { $0.id == id && $0.workspaceName == group.workspaceName } ||
                          appPins.contains { $0.id == id && $0.workspaceName == group.workspaceName }
                  }
              }),
              layoutWorkspaces.isSubset(of: Set(tree.roots.keys)), closedBrowserTabs.count <= 10000,
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
