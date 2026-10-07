import AppKit
import Common
import WorkspaceCore

extension BrowserWorkspaceController {
    func prunePinnedMembers() {
        let retained = Set(browserSidebarPins.map(\.id) + nativeAppSidebarPins.map(\.id))
        for index in pinnedDesktops.indices {
            let name = pinnedDesktops[index].workspaceName
            let owned = Set(browserSidebarPins.filter { $0.workspaceName == name }.map(\.id) + nativeAppSidebarPins.filter { $0.workspaceName == name }.map(\.id))
            pinnedDesktops[index].memberIDs.removeAll { !retained.contains($0) || !owned.contains($0) }
            pinnedDesktops[index].layout = pinnedDesktops[index].layout.compactMap { $0.keeping(owned) }
            if let selected = pinnedDesktops[index].selectedMember, !owned.contains(selected) { pinnedDesktops[index].selectedMember = nil }
        }
        for desktop in pinnedDesktops where desktop.memberIDs.isEmpty {
            if let workspace = Workspace.existing(byName: desktop.workspaceName) {
                workspace.isPinnedGroup = false
                if (surfaceTree.roots[workspace.name] ?? []).isEmpty && workspace.allLeafWindowsRecursive.isEmpty {
                    workspace.markAsTransientBlank()
                } else {
                    try? renameWorkspaceForSidebar(workspaceName: workspace.name, displayName: desktop.title)
                }
            }
            for shelf in pinShelves.indices { pinShelves[shelf].desktopOrder.removeAll { $0 == desktop.id } }
        }
        pinnedDesktops.removeAll { $0.memberIDs.isEmpty }
    }
    func pinBindings(in workspace: String) -> [UUID: SurfaceID] {
        Dictionary(uniqueKeysWithValues:
            browserSidebarPins.filter { $0.workspaceName == workspace }.compactMap { pin in pin.surfaceID.map { (pin.id, $0) } } +
            nativeAppSidebarPins.filter { $0.workspaceName == workspace }.compactMap { pin in pin.surfaceID.map { (pin.id, $0) } })
    }

    func ensurePinShelf(_ space: WorkspaceProjectId, source: Workspace? = nil) {
        guard !pinShelves.contains(where: { $0.spaceID == space.rawValue }) else { return }
        let regular = source.flatMap { $0.isPinnedGroup ? nil : $0.name }
            ?? spacePinnedGroups.first { $0.spaceID == space.rawValue }?.lastRegularWorkspaceName
        pinShelves.append(.init(spaceID: space.rawValue, lastRegularWorkspaceName: regular))
    }

    func capturePinnedLayouts() {
        normalizePinnedGroupIDs()
        for index in pinnedDesktops.indices {
            let desktop = pinnedDesktops[index]
            let bindings = pinBindings(in: desktop.workspaceName)
            let members = Dictionary(uniqueKeysWithValues: bindings.map { ($0.value, $0.key) })
            if let selected = focusCoordinator.target.flatMap({ members[$0] }) { pinnedDesktops[index].selectedMember = selected }
            // A close prunes the live tree. Preserve the complete saved template
            // until all slots are present, rather than saving that projection.
            let tiledMembers = Set(desktop.layout.flatMap(\.members))
            let liveTree = Set((surfaceTree.roots[desktop.workspaceName] ?? []).flatMap(\.surfaces))
            let allSlotsPresent = tiledMembers.allSatisfy { bindings[$0].map(liveTree.contains) ?? false }
            if bindings.count == desktop.memberIDs.count && allSlotsPresent {
                pinnedDesktops[index].layout = (surfaceTree.roots[desktop.workspaceName] ?? []).compactMap {
                    PinnedLayoutNode.capture($0, tree: surfaceTree, members: members)
                }
            } else {
                pinnedDesktops[index].layout = desktop.layout.map { $0.refreshing(from: surfaceTree, bindings: bindings) }
            }
        }
    }

    func restorePinnedDesktopLayout(workspace: String) {
        normalizePinnedGroupIDs()
        guard let desktop = pinnedDesktops.first(where: { $0.workspaceName == workspace }) else { return }
        applyPinnedTemplate(desktop.layout, bindings: pinBindings(in: workspace), workspace: workspace)
    }

    /// Moving a live subtree can leave closed slots in its former desktop.
    /// Their saved container must not reclaim the moved container's identity.
    private func normalizePinnedGroupIDs() {
        var owners: [UUID: String] = [:]
        func visit(_ node: SurfaceTreeNode, workspace: String) {
            if case .group(let id, let children) = node {
                owners[id] = workspace
                for child in children { visit(child, workspace: workspace) }
            }
        }
        for (workspace, nodes) in surfaceTree.roots {
            for node in nodes { visit(node, workspace: workspace) }
        }
        func normalize(_ node: PinnedLayoutNode, workspace: String) -> PinnedLayoutNode {
            guard case .group(let id, let layout, let children, let selected, let weight) = node else { return node }
            let resolved = (owners[id].map { $0 == workspace } ?? true) ? id : UUID()
            owners[resolved] = workspace
            return .group(resolved, layout, children.map { normalize($0, workspace: workspace) }, selected, weight)
        }
        for index in pinnedDesktops.indices {
            let workspace = pinnedDesktops[index].workspaceName
            pinnedDesktops[index].layout = pinnedDesktops[index].layout.map { normalize($0, workspace: workspace) }
        }
    }

    private func launchDescriptors(_ surfaces: [SurfaceID], workspace: String) -> ([BrowserSidebarPin], [NativeAppSidebarPin])? {
        var pages: [BrowserSidebarPin] = [], apps: [NativeAppSidebarPin] = []
        for surface in surfaces {
            if var page = sidebarPin(for: surface) { page.workspaceName = workspace; pages.append(page); continue }
            if var app = nativeAppSidebarPins.first(where: { $0.surfaceID == surface }) { app.workspaceName = workspace; apps.append(app); continue }
            switch surface {
            case .browserTab(let profile, _):
                guard let record = owner(of: surface)?.inventory.tabs[surface] else { return nil }
                pages.append(.init(profileID: profile, workspaceName: workspace,
                    title: record.title.isEmpty ? "New tab" : record.title,
                    url: record.url.isEmpty ? "about:blank" : record.url, surfaceID: surface, iconPNGBase64: record.iconPNGBase64))
            case .nativeWindow:
                guard let window = Window.get(bySurfaceID: surface), canAdoptNativePinWindow(window),
                      let bundle = window.app.rawAppBundleId, let path = window.app.bundlePath else { return nil }
                apps.append(.init(workspaceName: workspace, bundleIdentifier: bundle, bundlePath: path,
                                  title: window.app.name ?? bundle, surfaceID: surface))
            }
        }
        return (pages, apps)
    }

    @discardableResult
    func pinSurface(_ surface: SurfaceID, in space: WorkspaceProjectId? = nil) -> Bool {
        guard !isPrivateSurface(surface), space?.isIncognito != true else { return false }
        if let desktop = pinnedDesktops.first(where: { pinBindings(in: $0.workspaceName).values.contains(surface) }) {
            return space.map { movePin(desktop.id, to: $0) } ?? true
        }
        if let group = surfaceTree.outermostGroup(containing: surface) { return pinSurfaceGroup(group, in: space) }
        guard let source = workspaceName(for: surface).flatMap({ Workspace.existing(byName: $0) }), usesSurfaceTree else { return false }
        return createPinnedDesktop(nodes: [.surface(surface)], source: source, space: space ?? source.projectId, group: nil)
    }

    @discardableResult
    func pinSurfaceGroup(_ id: UUID, in space: WorkspaceProjectId? = nil) -> Bool {
        guard canMoveGroup(id), let node = surfaceTree.group(id),
              let source = workspaceName(forGroup: id).flatMap({ Workspace.existing(byName: $0) }) else { return false }
        return createPinnedDesktop(nodes: [node], source: source, space: space ?? source.projectId, group: id)
    }

    func separatePinnedDesktopMember(_ surface: SurfaceID) -> Bool {
        guard let source = workspaceName(for: surface).flatMap({ Workspace.existing(byName: $0) }),
              pinnedDesktops.contains(where: { $0.workspaceName == source.name && $0.memberIDs.count > 1 }) else { return false }
        return createPinnedDesktop(nodes: [.surface(surface)], source: source, space: source.projectId, group: nil)
    }

    @discardableResult
    func pinWorkspace(_ name: String) -> Bool {
        guard usesSurfaceTree, let source = Workspace.existing(byName: name), !source.isPinnedGroup,
              !source.isArchived, !source.isIncognito else { return false }
        let nodes = surfaceTree.roots[name] ?? []
        let tiled = Set(nodes.flatMap(\.surfaces))
        let floating = source.allLeafWindowsRecursive.map(\.surfaceID).filter { !tiled.contains($0) }
        guard !nodes.isEmpty || !floating.isEmpty,
              let descriptors = launchDescriptors(nodes.flatMap(\.surfaces) + floating, workspace: name) else { return false }
        let index = winMuxWorkspaceState.projectsById[source.projectId]?.workspaceOrder.firstIndex(of: source.id)
        installDesktop(descriptors: descriptors, nodes: nodes, source: source, destination: source,
                       kind: .group, title: workspaceDisplayName(name), formerIndex: index)
        scheduleRefresh()
        return true
    }

    private func createPinnedDesktop(nodes: [SurfaceTreeNode], source: Workspace, space: WorkspaceProjectId, group: UUID?, destination existing: Workspace? = nil) -> Bool {
        guard !space.isIncognito, !source.isIncognito, !nodes.flatMap(\.surfaces).contains(where: isPrivateSurface),
              winMuxWorkspaceState.projectsById[space] != nil else { return false }
        let name = existing?.name ?? "__pin_" + UUID().uuidString.lowercased()
        let destination = existing ?? Workspace.get(byName: name)
        destination.assignProject(space); destination.seedMonitorIfNeeded(source.workspaceMonitor)
        if let accepted = moveUsingDestinationProfile(nodes.flatMap(\.surfaces), to: destination, commit: { [weak self] in
            self?.createPinnedDesktop(nodes: nodes, source: source, space: space, group: group, destination: destination) ?? false
        }) { return accepted }
        guard let descriptors = launchDescriptors(nodes.flatMap(\.surfaces), workspace: name),
              browserSidebarPins.count + nativeAppSidebarPins.count + nodes.flatMap(\.surfaces).count <= 10000 else { return false }
        let originalTree = surfaceTree
        let selected = focusCoordinator.target ?? focus.windowOrNil?.surfaceID
        if let group {
            guard moveGroup(group, to: destination) else { return false }
        } else if let member = nodes.first?.surfaces.first {
            guard adoptPinnedSurface(member, into: name) else { return false }
        }
        let kind: PinnedDesktop.Kind = group != nil ? .group : descriptors.0.isEmpty ? .app : .tab
        let titles = descriptors.0.map(\.title) + descriptors.1.map(\.title)
        installDesktop(descriptors: descriptors, nodes: nodes, source: source, destination: destination,
                       kind: kind, title: titles.prefix(2).joined(separator: " + "), tree: originalTree)
        if let selected, nodes.flatMap(\.surfaces).contains(selected) { _ = select(selected) }
        scheduleRefresh()
        return true
    }

    private func installDesktop(descriptors: ([BrowserSidebarPin], [NativeAppSidebarPin]), nodes: [SurfaceTreeNode],
                                source: Workspace, destination: Workspace, kind: PinnedDesktop.Kind, title: String,
                                formerIndex: Int? = nil, tree: SurfaceTree? = nil) {
        ensurePinShelf(destination.projectId, source: source)
        let members = descriptors.0.map(\.id) + descriptors.1.map(\.id)
        let ids = Set(members)
        for index in pinnedDesktops.indices {
            pinnedDesktops[index].memberIDs.removeAll { ids.contains($0) }
            let retained = Set(pinnedDesktops[index].memberIDs)
            pinnedDesktops[index].layout = pinnedDesktops[index].layout.compactMap { $0.keeping(retained) }
            if let selected = pinnedDesktops[index].selectedMember, !retained.contains(selected) { pinnedDesktops[index].selectedMember = nil }
        }
        prunePinnedMembers()
        browserSidebarPins.removeAll { ids.contains($0.id) }; nativeAppSidebarPins.removeAll { ids.contains($0.id) }
        browserSidebarPins += descriptors.0; nativeAppSidebarPins += descriptors.1
        for id in members { removePinOrder(id) }
        let bindings = pinBindings(in: destination.name)
        let reverse = Dictionary(uniqueKeysWithValues: bindings.map { ($0.value, $0.key) })
        let desktop = PinnedDesktop(id: kind == .group ? UUID() : members[0], spaceID: destination.projectId.rawValue,
            workspaceName: destination.name, title: title, kind: kind, memberIDs: members,
            layout: nodes.compactMap { PinnedLayoutNode.capture($0, tree: tree ?? surfaceTree, members: reverse) },
            selectedMember: (focusCoordinator.target ?? focus.windowOrNil?.surfaceID).flatMap { reverse[$0] }, formerRegularIndex: formerIndex)
        pinnedDesktops.append(desktop)
        if let shelf = pinShelves.firstIndex(where: { $0.spaceID == desktop.spaceID }) { pinShelves[shelf].desktopOrder.append(desktop.id) }
        destination.isPinnedGroup = true; destination.lifecycle = .durable
        if let shelf = pinShelves.firstIndex(where: { $0.spaceID == desktop.spaceID }), pinShelves[shelf].lastRegularWorkspaceName == destination.name {
            pinShelves[shelf].lastRegularWorkspaceName = projectWorkspaces(projectId: destination.projectId).first { !$0.isPinnedGroup && !$0.isArchived }?.name
        }
    }

    @discardableResult
    func selectPin(_ id: UUID) -> SurfaceActionOutcome {
        guard let desktop = pinnedDesktops.first(where: { $0.id == id }) else { return legacySelectPin(id) }
        let bindings = pinBindings(in: desktop.workspaceName)
        let live = bindings.filter { isAvailable($0.value) }
        if let selected = desktop.selectedMember.flatMap({ live[$0] }) ?? desktop.memberIDs.compactMap({ live[$0] }).first {
            return select(selected)
        }
        _ = Workspace.existing(byName: desktop.workspaceName)?.focusWorkspace()
        return reopenClosedPinItems(id)
    }

    @discardableResult
    func reopenClosedPinItems(_ id: UUID) -> SurfaceActionOutcome {
        guard let desktop = pinnedDesktops.first(where: { $0.id == id }) else { return .unavailable }
        var issued = false
        let bindings = pinBindings(in: desktop.workspaceName)
        let hasLiveMember = bindings.values.contains(where: isAvailable)
        let selected = hasLiveMember ? nil : desktop.selectedMember ?? desktop.memberIDs.first
        // Start the selected member last so completion order cannot steal focus.
        let order = desktop.memberIDs.filter { $0 != selected } + (selected.map { [$0] } ?? [])
        for member in order where bindings[member].map(isAvailable) != true {
            if legacySelectPin(member, selectAfterOpening: member == selected) == .issued { issued = true }
        }
        return issued ? .issued : .unavailable
    }

    @discardableResult
    func unpin(_ id: UUID, to destination: Workspace? = nil) -> Bool {
        guard let index = pinnedDesktops.firstIndex(where: { $0.id == id || $0.memberIDs.contains(id) }),
              let workspace = Workspace.existing(byName: pinnedDesktops[index].workspaceName) else { return legacyUnpin(id, to: destination) }
        let desktop = pinnedDesktops[index]
        if let destination {
            guard !destination.isPinnedGroup, !destination.isIncognito, transferPinnedWorkspace(workspace, to: destination) else { return false }
        }
        let members = Set(desktop.memberIDs)
        for member in members { pendingSidebarPinOpenings.remove(member); pendingNativePinLaunches.removeValue(forKey: member); failedNativePinLaunches.remove(member) }
        browserSidebarPins.removeAll { members.contains($0.id) }; nativeAppSidebarPins.removeAll { members.contains($0.id) }
        pinnedDesktops.remove(at: index)
        for shelf in pinShelves.indices { pinShelves[shelf].desktopOrder.removeAll { $0 == desktop.id } }
        workspace.isPinnedGroup = false
        if destination == nil {
            try? renameWorkspaceForSidebar(workspaceName: workspace.name, displayName: desktop.title)
            if var project = winMuxWorkspaceState.projectsById[workspace.projectId] {
                project.workspaceOrder.removeAll { $0 == workspace.id }
                project.workspaceOrder.insert(workspace.id, at: min(desktop.formerRegularIndex ?? project.workspaceOrder.count, project.workspaceOrder.count))
                winMuxWorkspaceState.registerProject(project)
            }
        }
        scheduleRefresh()
        return true
    }

    @discardableResult
    func movePin(_ id: UUID, to space: WorkspaceProjectId) -> Bool {
        guard let index = pinnedDesktops.firstIndex(where: { $0.id == id || $0.memberIDs.contains(id) }) else { return legacyMovePin(id, to: space) }
        guard !space.isIncognito, winMuxWorkspaceState.projectsById[space] != nil, let workspace = Workspace.existing(byName: pinnedDesktops[index].workspaceName) else { return false }
        guard pinnedDesktops[index].spaceID != space.rawValue else { return true }
        let destination = Workspace.get(byName: "__pin_" + UUID().uuidString.lowercased())
        destination.assignProject(space); destination.seedMonitorIfNeeded(workspace.workspaceMonitor)
        return movePinnedDesktop(pinnedDesktops[index].id, to: destination)
    }

    private func movePinnedDesktop(_ id: UUID, to destination: Workspace) -> Bool {
        guard let index = pinnedDesktops.firstIndex(where: { $0.id == id }),
              let workspace = Workspace.existing(byName: pinnedDesktops[index].workspaceName),
              !destination.isIncognito else { return false }
        let members = Set(pinnedDesktops[index].memberIDs)
        let pages = browserSidebarPins.filter { members.contains($0.id) }
        let closed = pages.filter { $0.surfaceID == nil }
        // A group must have all of its browser slots open before a profile
        // transfer. A closed standalone pin can reopen transactionally.
        guard closed.isEmpty || (pages.count == 1 && members.count == 1) else { return false }
        let surfaces = Array(pinBindings(in: workspace.name).values).filter(isAvailable)
        if let accepted = moveUsingDestinationProfile(surfaces, closedPin: closed.first, to: destination, commit: { [weak self] in
            self?.movePinnedDesktop(id, to: destination) ?? false
        }) { return accepted }
        capturePinnedLayouts()
        guard transferPinnedWorkspace(workspace, to: destination) else { return false }
        let space = destination.projectId
        let desktopID = pinnedDesktops[index].id
        ensurePinShelf(space)
        for shelf in pinShelves.indices { pinShelves[shelf].desktopOrder.removeAll { $0 == desktopID } }
        pinnedDesktops[index].spaceID = space.rawValue; pinnedDesktops[index].formerRegularIndex = nil
        pinnedDesktops[index].workspaceName = destination.name
        for i in browserSidebarPins.indices where members.contains(browserSidebarPins[i].id) { browserSidebarPins[i].workspaceName = destination.name }
        for i in nativeAppSidebarPins.indices where members.contains(nativeAppSidebarPins[i].id) { nativeAppSidebarPins[i].workspaceName = destination.name }
        destination.isPinnedGroup = true; destination.lifecycle = .durable
        workspace.isPinnedGroup = false; workspace.markAsTransientBlank()
        if let shelf = pinShelves.firstIndex(where: { $0.spaceID == space.rawValue }) { pinShelves[shelf].desktopOrder.append(desktopID) }
        scheduleRefresh(); return true
    }

    func reorderPin(_ id: UUID, before target: UUID) {
        guard let shelf = pinShelves.firstIndex(where: { $0.desktopOrder.contains(id) && $0.desktopOrder.contains(target) }), id != target else { legacyReorderPin(id, before: target); return }
        pinShelves[shelf].desktopOrder.removeAll { $0 == id }
        if let index = pinShelves[shelf].desktopOrder.firstIndex(of: target) { pinShelves[shelf].desktopOrder.insert(id, at: index) }
        scheduleRefresh()
    }

    func discardPins(in space: WorkspaceProjectId) {
        for id in pinnedDesktops.filter({ $0.spaceID == space.rawValue }).map(\.id) { _ = unpin(id) }
        legacyDiscardPins(in: space); pinShelves.removeAll { $0.spaceID == space.rawValue }
    }

    func movePins(in space: WorkspaceProjectId, to destination: WorkspaceProjectId) {
        for id in pinnedDesktops.filter({ $0.spaceID == space.rawValue }).map(\.id) { _ = movePin(id, to: destination) }
        legacyMovePins(in: space, to: destination)
    }

    func pinTiles(in workspace: String) -> [WorkspaceSidebarPinViewModel] {
        guard let desktop = pinnedDesktops.first(where: { $0.workspaceName == workspace }) else { return legacyPinTiles(in: workspace) }
        let members = makeMemberPinTiles(in: workspace, browserPins: browserSidebarPins.filter { $0.workspaceName == workspace }, nativePins: nativeAppSidebarPins.filter { $0.workspaceName == workspace })
        guard var tile = members.first else { return [] }
        tile.id = desktop.id; tile.title = desktop.kind == .group ? desktop.title : tile.title
        tile.sortOrder = pinShelves.first { $0.spaceID == desktop.spaceID }?.desktopOrder.firstIndex(of: desktop.id) ?? 0
        tile.members = desktop.kind == .group ? members : []
        tile.groupMembers = tile.members
        tile.isGroup = desktop.kind == .group; tile.memberCount = desktop.memberIDs.count
        tile.isFocused = members.contains(where: \.isFocused); tile.isOpen = members.contains(where: \.isOpen)
        tile.isSelected = members.contains(where: \.isSelected)
        tile.isLoading = members.contains(where: \.isLoading); tile.isUnavailable = members.allSatisfy(\.isUnavailable)
        tile.surfaceID = members.first(where: \.isFocused)?.surfaceID ?? members.first(where: \.isOpen)?.surfaceID
        return [tile]
    }

    func pinTilesByWorkspace() -> [String: [WorkspaceSidebarPinViewModel]] {
        syncSidebarPins()
        let workspaces = Set(pinnedDesktops.map(\.workspaceName) + browserSidebarPins.map(\.workspaceName) + nativeAppSidebarPins.map(\.workspaceName))
        return Dictionary(uniqueKeysWithValues: workspaces.map { ($0, pinTiles(in: $0)) })
    }

    func migratePinnedDesktops() {
        // Existing v5 desktops are never repartitioned. Legacy metadata remains
        // readable until owners provide launch descriptors for every group member.
        let migrated = Set(pinnedDesktops.flatMap(\.memberIDs))
        let legacyPages = browserSidebarPins.filter { !migrated.contains($0.id) }
        let legacyApps = nativeAppSidebarPins.filter { !migrated.contains($0.id) }
        let sources = Set(legacyPages.map(\.workspaceName) + legacyApps.map(\.workspaceName))
        for name in sources.sorted() {
            guard let source = Workspace.existing(byName: name) else { continue }
            ensurePinShelf(source.projectId, source: source)
            let order = spacePinnedGroups.first { $0.workspaceName == name }?.pinOrder
                ?? (legacyPages.filter { $0.workspaceName == name }.map(\.id) + legacyApps.filter { $0.workspaceName == name }.map(\.id))
            for id in order {
                if pinnedDesktops.contains(where: { $0.memberIDs.contains(id) }) || isGroupedPin(id) { continue }
                let page = browserSidebarPins.first { $0.id == id }, app = nativeAppSidebarPins.first { $0.id == id }
                let surface = page?.surfaceID ?? app?.surfaceID
                if let surface, let group = surfaceTree.outermostGroup(containing: surface), let node = surfaceTree.group(group) {
                    _ = migrateLegacyNodes([node], source: source, kind: .group)
                } else if let surface, surfaceTree.workspace(of: surface) != nil {
                    _ = migrateLegacyNodes([.surface(surface)], source: source, kind: page == nil ? .app : .tab)
                } else {
                    let destination = Workspace.get(byName: "__pin_" + id.uuidString.lowercased())
                    destination.assignProject(source.projectId); destination.seedMonitorIfNeeded(source.workspaceMonitor)
                    var pages = page.map { [$0] } ?? [], apps = app.map { [$0] } ?? []
                    for i in pages.indices { pages[i].workspaceName = destination.name }
                    for i in apps.indices { apps[i].workspaceName = destination.name }
                    guard !pages.isEmpty || !apps.isEmpty else { continue }
                    installDesktop(descriptors: (pages, apps), nodes: [], source: source, destination: destination,
                                   kind: page == nil ? .app : .tab, title: page?.title ?? app?.title ?? "Pinned")
                }
            }
        }
    }

    private func migrateLegacyNodes(_ nodes: [SurfaceTreeNode], source: Workspace, kind: PinnedDesktop.Kind) -> Bool {
        let name = "__pin_" + UUID().uuidString.lowercased()
        guard let descriptors = launchDescriptors(nodes.flatMap(\.surfaces), workspace: name) else { return false }
        let original = surfaceTree
        let destination = Workspace.get(byName: name)
        destination.assignProject(source.projectId); destination.seedMonitorIfNeeded(source.workspaceMonitor)
        migratePinnedNodes(nodes, from: source.name, to: name)
        installDesktop(descriptors: descriptors, nodes: nodes, source: source, destination: destination,
                       kind: kind, title: (descriptors.0.map(\.title) + descriptors.1.map(\.title)).prefix(2).joined(separator: " + "), tree: original)
        return true
    }
}
