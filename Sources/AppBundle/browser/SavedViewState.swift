import Foundation
import WorkspaceCore

/// Legacy records are adapters over saved View members. Only records that have
/// not yet crossed the migration boundary remain in the legacy arrays.
extension BrowserWorkspaceController {
    var pinnedViews: [SavedView] {
        get { savedViews.filter(\.isPinned) }
        set { savedViews = savedViews.filter { !$0.isPinned } + newValue }
    }
    var browserSidebarPins: [BrowserSidebarPin] {
        get {
            orderedPinRecords(legacyBrowserPins + pinnedViews.flatMap { view in
                view.members.compactMap { $0.browserPin(in: view.workspaceName) }
            }, order: browserMemberOrder)
        }
        set {
            browserMemberOrder = newValue.map(\.id)
            let byWorkspace = Dictionary(grouping: newValue, by: \.workspaceName)
            for index in pinnedViews.indices {
                replacePinMembers(in: index, with: (byWorkspace[pinnedViews[index].workspaceName] ?? []).map(ViewMember.init), replacing: {
                    if case .browser = $0.launch { return true }; return false
                })
            }
            let owned = Set(pinnedViews.map(\.workspaceName))
            legacyBrowserPins = newValue.filter { !owned.contains($0.workspaceName) }
        }
    }

    var nativeAppSidebarPins: [NativeAppSidebarPin] {
        get {
            orderedPinRecords(legacyAppPins + pinnedViews.flatMap { view in
                view.members.compactMap { $0.appPin(in: view.workspaceName) }
            }, order: appMemberOrder)
        }
        set {
            appMemberOrder = newValue.map(\.id)
            let byWorkspace = Dictionary(grouping: newValue, by: \.workspaceName)
            for index in pinnedViews.indices {
                replacePinMembers(in: index, with: (byWorkspace[pinnedViews[index].workspaceName] ?? []).map(ViewMember.init), replacing: {
                    if case .application = $0.launch { return true }; return false
                })
            }
            let owned = Set(pinnedViews.map(\.workspaceName))
            legacyAppPins = newValue.filter { !owned.contains($0.workspaceName) }
        }
    }

    func restoreSavedPinState(_ snapshot: SurfaceWorkspaceSnapshot) {
        savedViews = snapshot.savedViews.filter { !$0.isPinned } + snapshot.pinnedDesktops.compactMap {
            $0.savedView(browserPins: snapshot.browserPins, appPins: snapshot.appPins)
        }
        let migrated = Set(pinnedViews.flatMap(\.memberIDs))
        legacyBrowserPins = snapshot.browserPins.filter { !migrated.contains($0.id) }
        legacyAppPins = snapshot.appPins.filter { !migrated.contains($0.id) }
        browserMemberOrder = snapshot.browserPins.map(\.id)
        appMemberOrder = snapshot.appPins.map(\.id)
    }

    func installSavedPinView(_ view: SavedView) {
        let members = Set(view.memberIDs)
        legacyBrowserPins.removeAll { members.contains($0.id) }
        legacyAppPins.removeAll { members.contains($0.id) }
        savedViews.removeAll { $0.id == view.id || $0.workspaceName == view.workspaceName }
        savedViews.append(view)
        for member in view.members {
            if case .browser = member.launch, !browserMemberOrder.contains(member.id) { browserMemberOrder.append(member.id) }
            if case .application = member.launch, !appMemberOrder.contains(member.id) { appMemberOrder.append(member.id) }
        }
    }

    func savedMemberID(for surface: SurfaceID) -> UUID? {
        savedViews.lazy.flatMap(\.members).first { $0.surfaceID == surface }?.id
    }

    /// A successful profile transaction replaces the live page, not the saved
    /// member. Discard any temporary copy slot before transferring the binding.
    func replaceSavedBinding(_ old: SurfaceID, with replacement: SurfaceID) {
        guard old != replacement, savedMemberID(for: old) != nil else { return }
        for view in savedViews.indices {
            savedViews[view].members.removeAll { $0.surfaceID == replacement }
            for member in savedViews[view].members.indices where savedViews[view].members[member].surfaceID == old {
                savedViews[view].members[member].surfaceID = replacement
                if case .browser(_, let url) = savedViews[view].members[member].launch,
                   let profile = replacement.browserProfileID {
                    savedViews[view].members[member].launch = .browser(profileID: profile, url: url)
                }
            }
            let retained = Set(savedViews[view].memberIDs)
            savedViews[view].layout = savedViews[view].layout.compactMap { $0.keeping(retained) }
            if let selected = savedViews[view].selectedMember, !retained.contains(selected) {
                savedViews[view].selectedMember = nil
            }
        }
    }

    /// Regular Views retain identities across moves and checkpoints, but only
    /// explicit pins retain closed slots and launch descriptors.
    func reconcileSavedViews() {
        guard usesSurfaceTree else { return }
        let existing = savedViews.filter { !$0.isPinned }.reduce(into: [String: SavedView]()) { $0[$1.workspaceName] = $1 }
        let members = savedViews.flatMap(\.members).reduce(into: [SurfaceID: ViewMember]()) {
            if let surface = $1.surfaceID { $0[surface] = $1 }
        }
        let pendingLegacy = Set(legacyBrowserPins.map(\.workspaceName) + legacyAppPins.map(\.workspaceName))
        var regular: [SavedView] = []
        for workspace in Workspace.all where !workspace.isArchived && !workspace.isPinnedGroup && !workspace.isIncognito {
            // An old partially saved group may still need native discovery.
            // Keep its original tree and descriptors at the migration boundary
            // instead of recording the same bindings in a second View.
            guard !pendingLegacy.contains(workspace.name) else { continue }
            let nodes = surfaceTree.roots[workspace.name] ?? []
            let tiled = nodes.flatMap(\.surfaces)
            let ids = tiled + workspace.allLeafWindowsRecursive.map(\.surfaceID).filter { !tiled.contains($0) }
            guard workspace.lifecycle == .durable || !ids.isEmpty else { continue }
            let title = config.workspaceSidebar.workspaceLabels[workspace.name] ?? workspace.name
            var view = existing[workspace.name] ?? SavedView(spaceID: workspace.projectId.rawValue,
                workspaceName: workspace.name, title: title)
            view.spaceID = workspace.projectId.rawValue
            view.title = title
            view.retainsWhenEmpty = workspace.retainsEmptyView
            view.members = ids.map { id in
                var member = members[id] ?? ViewMember(title: "", surfaceID: id)
                member.launch = nil; member.iconPNGBase64 = nil
                switch id {
                case .nativeWindow: member.title = Window.get(bySurfaceID: id)?.app.name ?? member.title
                case .browserTab: member.title = owner(of: id)?.inventory.tabs[id]?.title ?? member.title
                }
                return member
            }
            let reverse = Dictionary(uniqueKeysWithValues: view.members.compactMap { member in member.surfaceID.map { ($0, member.id) } })
            view.layout = nodes.compactMap { ViewLayoutNode.capture($0, tree: surfaceTree, members: reverse) }
            view.selectedMember = (selectedByWorkspace[workspace.name] ?? focusCoordinator.target).flatMap { reverse[$0] }
            regular.append(view)
        }
        savedViews = pinnedViews + regular
    }

    func retainUnpinnedView(_ view: SavedView, in workspace: Workspace) {
        let ids = Set((surfaceTree.roots[workspace.name] ?? []).flatMap(\.surfaces) + workspace.allLeafWindowsRecursive.map(\.surfaceID))
        var regular = view
        regular.isPinned = false
        regular.workspaceName = workspace.name; regular.spaceID = workspace.projectId.rawValue
        regular.members = view.members.filter { $0.surfaceID.map(ids.contains) ?? false }.map {
            var member = $0; member.launch = nil; member.iconPNGBase64 = nil; return member
        }
        if let index = savedViews.firstIndex(where: { !$0.isPinned && $0.workspaceName == workspace.name }) {
            let existing = Set(savedViews[index].memberIDs)
            savedViews[index].members += regular.members.filter { !existing.contains($0.id) }
        } else { savedViews.append(regular) }
        reconcileSavedViews()
    }

    private func replacePinMembers(in index: Int, with records: [ViewMember], replacing: (ViewMember) -> Bool) {
        let byID = records.reduce(into: [UUID: ViewMember]()) { $0[$1.id] = $1 }
        pinnedViews[index].members = pinnedViews[index].members.compactMap { replacing($0) ? byID[$0.id] : $0 }
        let existing = Set(pinnedViews[index].memberIDs)
        let added = records.filter { !existing.contains($0.id) }
        pinnedViews[index].members += added
        if !added.isEmpty {
            pinnedViews[index].kind = .group
            let saved = Set(pinnedViews[index].layout.flatMap(\.members))
            pinnedViews[index].layout += added.filter { !saved.contains($0.id) }.map { .member($0.id, 1) }
        }
    }
}

private func orderedPinRecords<T: Identifiable>(_ records: [T], order: [UUID]) -> [T] where T.ID == UUID {
    let positions = order.enumerated().reduce(into: [UUID: Int]()) { $0[$1.element] = $1.offset }
    return records.enumerated().sorted {
        (positions[$0.element.id] ?? (order.count + $0.offset)) < (positions[$1.element.id] ?? (order.count + $1.offset))
    }.map(\.element)
}
