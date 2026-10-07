import Foundation

public enum SurfaceSnapshotError: Error { case invalidTree }

/// Ordinary workspace membership stores references only. Explicit sidebar pins
/// also store the user-selected page title and URL so a closed pin can reopen.
/// Restoration never creates browser tabs; live membership remains owner-owned.
public struct SurfaceWorkspaceSnapshot: Codable, Equatable, Sendable {
    public var tree: SurfaceTree
    public var layoutWorkspaces: Set<String>
    public var selected: SurfaceID?
    public var selectedByWorkspace: [String: SurfaceID]
    public var closedBrowserTabs: Set<SurfaceID>

    public var savedViews: [SavedView]
    private var legacyBrowserPins: [BrowserSidebarPin]
    private var legacyAppPins: [NativeAppSidebarPin]
    private var legacyPinnedDesktops: [PinnedDesktop]
    public var pinnedGroups: [SpacePinnedGroup]
    public var pinShelves: [SpacePinShelf]
    public var browserProfiles: [WorkspaceBrowserProfile]
    public var browserProfileBySpace: [String: UUID]

    public var browserPins: [BrowserSidebarPin] {
        legacyBrowserPins + savedViews.filter(\.isPinned).flatMap { view in
            view.members.compactMap { $0.browserPin(in: view.workspaceName) }
        }
    }
    public var appPins: [NativeAppSidebarPin] {
        legacyAppPins + savedViews.filter(\.isPinned).flatMap { view in
            view.members.compactMap { $0.appPin(in: view.workspaceName) }
        }
    }
    public var pinnedDesktops: [PinnedDesktop] { legacyPinnedDesktops + savedViews.filter(\.isPinned).map(\.legacyDesktop) }

    public init(tree: SurfaceTree, layoutWorkspaces: Set<String>, selected: SurfaceID?, closedBrowserTabs: Set<SurfaceID>,
                browserPins: [BrowserSidebarPin] = [], appPins: [NativeAppSidebarPin] = [], pinnedGroups: [SpacePinnedGroup] = [],
                pinnedDesktops: [PinnedDesktop] = [], pinShelves: [SpacePinShelf] = [],
                selectedByWorkspace: [String: SurfaceID] = [:], browserProfiles: [WorkspaceBrowserProfile] = [],
                browserProfileBySpace: [String: UUID] = [:], savedViews: [SavedView] = []) {
        self.tree = tree; self.layoutWorkspaces = layoutWorkspaces
        self.selected = selected; self.closedBrowserTabs = closedBrowserTabs
        self.selectedByWorkspace = selectedByWorkspace
        self.legacyBrowserPins = browserPins; self.legacyAppPins = appPins; self.pinnedGroups = pinnedGroups
        self.legacyPinnedDesktops = pinnedDesktops; self.pinShelves = pinShelves; self.savedViews = savedViews
        self.browserProfiles = browserProfiles; self.browserProfileBySpace = browserProfileBySpace
    }

    private enum CodingKeys: String, CodingKey { case tree, layoutWorkspaces, selected, closedBrowserTabs, browserPins, appPins, pinnedGroups, pinnedDesktops, pinShelves, selectedByWorkspace, browserProfiles, browserProfileBySpace, savedViews }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(tree, forKey: .tree)
        try values.encode(layoutWorkspaces, forKey: .layoutWorkspaces)
        try values.encodeIfPresent(selected, forKey: .selected)
        try values.encode(selectedByWorkspace, forKey: .selectedByWorkspace)
        try values.encode(closedBrowserTabs, forKey: .closedBrowserTabs)
        try values.encode(savedViews, forKey: .savedViews)
        // Retain only unresolved legacy records. Migrated launch descriptors and
        // layouts are encoded once, in their owning saved View.
        if !legacyBrowserPins.isEmpty { try values.encode(legacyBrowserPins, forKey: .browserPins) }
        if !legacyAppPins.isEmpty { try values.encode(legacyAppPins, forKey: .appPins) }
        if !legacyPinnedDesktops.isEmpty { try values.encode(legacyPinnedDesktops, forKey: .pinnedDesktops) }
        try values.encode(pinnedGroups, forKey: .pinnedGroups)
        try values.encode(pinShelves, forKey: .pinShelves)
        try values.encode(browserProfiles, forKey: .browserProfiles)
        try values.encode(browserProfileBySpace, forKey: .browserProfileBySpace)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tree: try values.decode(SurfaceTree.self, forKey: .tree),
                  layoutWorkspaces: try values.decode(Set<String>.self, forKey: .layoutWorkspaces),
                  selected: try values.decodeIfPresent(SurfaceID.self, forKey: .selected),
                  closedBrowserTabs: try values.decode(Set<SurfaceID>.self, forKey: .closedBrowserTabs),
                  browserPins: try values.decodeIfPresent([BrowserSidebarPin].self, forKey: .browserPins) ?? [],
                  appPins: try values.decodeIfPresent([NativeAppSidebarPin].self, forKey: .appPins) ?? [],
                  pinnedGroups: try values.decodeIfPresent([SpacePinnedGroup].self, forKey: .pinnedGroups) ?? [],
                  pinnedDesktops: try values.decodeIfPresent([PinnedDesktop].self, forKey: .pinnedDesktops) ?? [],
                  pinShelves: try values.decodeIfPresent([SpacePinShelf].self, forKey: .pinShelves) ?? [],
                  selectedByWorkspace: try values.decodeIfPresent([String: SurfaceID].self, forKey: .selectedByWorkspace) ?? [:],
                  browserProfiles: try values.decodeIfPresent([WorkspaceBrowserProfile].self, forKey: .browserProfiles) ?? [],
                  browserProfileBySpace: try values.decodeIfPresent([String: UUID].self, forKey: .browserProfileBySpace) ?? [:],
                  savedViews: try values.decodeIfPresent([SavedView].self, forKey: .savedViews) ?? [])
    }

    public func validated() throws -> Self {
        let savedMembers = savedViews.flatMap(\.members)
        let memberIDs = savedMembers.map(\.id) + legacyBrowserPins.map(\.id) + legacyAppPins.map(\.id)
        let bindings = savedMembers.compactMap(\.surfaceID) + legacyBrowserPins.compactMap(\.surfaceID) + legacyAppPins.compactMap(\.surfaceID)
        var savedGroups = Set<UUID>()
        guard savedViews.count <= 20000, savedViews.allSatisfy(\.isValid),
              Set(savedViews.map(\.id)).count == savedViews.count,
              Set(savedViews.map(\.workspaceName)).count == savedViews.count,
              memberIDs.count <= 20000, Set(memberIDs).count == memberIDs.count,
              Set(bindings).count == bindings.count, Set(bindings).isDisjoint(with: closedBrowserTabs),
              savedViews.flatMap(\.layout).allSatisfy({ $0.validate(depth: 0, groups: &savedGroups) }),
              savedViews.allSatisfy({ view in view.members.allSatisfy { member in
                  member.surfaceID.flatMap { tree.workspace(of: $0) }.map { $0 == view.workspaceName } ?? true
              } }) else { throw SurfaceSnapshotError.invalidTree }
        let profiles = Set(browserProfiles.map(\.id))
        guard browserProfiles.count <= WorkspaceBrowserProfile.maximumCount, profiles.count == browserProfiles.count,
              browserProfiles.allSatisfy(\.isValid), browserProfileBySpace.count <= 1024,
              browserProfileBySpace.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 256 && profiles.contains($0.value) })
        else { throw SurfaceSnapshotError.invalidTree }
        let pinnedSurfaces = browserPins.compactMap(\.surfaceID) + appPins.compactMap(\.surfaceID)
        let pinIDs = browserPins.map(\.id) + appPins.map(\.id)
        let viewIDs = pinnedGroups.flatMap { $0.views.map(\.id) }
        guard Set(viewIDs).count == viewIDs.count, Set(viewIDs).isDisjoint(with: pinIDs),
              pinIDs.count <= 10000, Set(pinIDs).count == pinIDs.count, browserPins.allSatisfy(\.isValid),
              appPins.allSatisfy(\.isValid), pinnedGroups.allSatisfy(\.isValid),
              Set(pinnedGroups.map(\.spaceID)).count == pinnedGroups.count,
              Set(pinnedGroups.map(\.workspaceName)).count == pinnedGroups.count,
              appPins.allSatisfy({ pin in pinnedGroups.contains { $0.workspaceName == pin.workspaceName } || pinnedDesktops.contains { $0.workspaceName == pin.workspaceName } }),
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
              selectedByWorkspace.count <= 1024,
              selectedByWorkspace.allSatisfy({ tree.workspace(of: $0.value) == $0.key }),
              Set(tree.roots.values.flatMap { $0.flatMap(\.surfaces) }).isDisjoint(with: closedBrowserTabs)
        else { throw SurfaceSnapshotError.invalidTree }
        var templateGroups = Set<UUID>()
        guard pinnedDesktops.flatMap(\.layout).allSatisfy({ $0.validate(depth: 0, groups: &templateGroups) }) else { throw SurfaceSnapshotError.invalidTree }
        let desktopIDs = pinnedDesktops.map(\.id)
        let members = pinnedDesktops.flatMap(\.memberIDs)
        guard pinnedDesktops.allSatisfy(\.isValid), Set(desktopIDs).count == desktopIDs.count,
              Set(pinnedDesktops.map(\.workspaceName)).count == pinnedDesktops.count,
              Set(members).count == members.count, Set(members).isSubset(of: Set(pinIDs)),
              Set(pinShelves.map(\.spaceID)).count == pinShelves.count,
              Set(pinShelves.flatMap(\.desktopOrder)) == Set(desktopIDs),
              pinShelves.allSatisfy({ shelf in
                  !shelf.spaceID.isEmpty && shelf.spaceID.utf8.count <= 1024 &&
                  (shelf.lastRegularWorkspaceName.map { $0.utf8.count <= 1024 } ?? true) &&
                  Set(shelf.desktopOrder).count == shelf.desktopOrder.count &&
                  shelf.desktopOrder.allSatisfy { id in pinnedDesktops.contains { $0.id == id && $0.spaceID == shelf.spaceID } }
              }),
              pinnedDesktops.allSatisfy({ desktop in desktop.memberIDs.allSatisfy { id in
                  browserPins.contains { $0.id == id && $0.workspaceName == desktop.workspaceName } ||
                  appPins.contains { $0.id == id && $0.workspaceName == desktop.workspaceName }
              } }) else { throw SurfaceSnapshotError.invalidTree }
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
