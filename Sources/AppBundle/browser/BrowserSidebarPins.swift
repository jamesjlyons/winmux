import AppKit
import WorkspaceCore

extension BrowserWorkspaceController {
    func sidebarPin(for surfaceID: SurfaceID) -> BrowserSidebarPin? {
        browserSidebarPins.first { $0.surfaceID == surfaceID }
    }

    @discardableResult
    func pinBrowserTab(_ surfaceID: SurfaceID) -> Bool {
        pinSurface(surfaceID)
    }

    func unpinBrowserTab(_ id: UUID) { unpin(id) }

    @discardableResult
    func selectPinnedBrowserTab(_ id: UUID, selectAfterOpening: Bool = true) -> SurfaceActionOutcome {
        guard let pin = browserSidebarPins.first(where: { $0.id == id }) else { return .unavailable }
        if let surfaceID = pin.surfaceID, isAvailable(surfaceID) { return select(surfaceID) }
        // A lost helper connection is not confirmation that a live page closed.
        if let surfaceID = pin.surfaceID, unresolvedSidebarPinOwners[surfaceID] != nil { return .unavailable }
        guard pendingSidebarPinOpenings.insert(id).inserted else { return .issued }
        let result = openBrowserTab(url: pin.url, workspaceName: pin.workspaceName, profileID: pin.profileID, selectNewPage: selectAfterOpening, created: { [weak self] surfaceID in
            guard let self else { return }
            guard let index = self.browserSidebarPins.firstIndex(where: { $0.id == id }) else {
                if let group = Workspace.existing(byName: pin.workspaceName) {
                    _ = self.adoptPinnedSurface(surfaceID, into: self.regularWorkspaceForNewItem(group).name)
                    if self.focusCoordinator.target == surfaceID { _ = self.select(surfaceID) }
                }
                return
            }
            guard case .browserTab(let profile, _) = surfaceID, profile == pin.profileID,
                  !self.browserSidebarPins.contains(where: { $0.id != id && $0.surfaceID == surfaceID }) else {
                self.pendingSidebarPinOpenings.remove(id)
                return
            }
            if let previous = self.browserSidebarPins[index].surfaceID, previous != surfaceID {
                self.retireAbsentPinnedPage(previous)
            }
            self.browserSidebarPins[index].surfaceID = surfaceID
            let destination = self.browserSidebarPins[index].workspaceName
            if self.workspaceName(for: surfaceID) != destination {
                self.placeCreatedBrowserTab(surfaceID, in: destination, focusAddress: false, selectCreated: false, focusGeneration: self.focusCoordinator.generation)
                if self.focusCoordinator.target == surfaceID { _ = self.select(surfaceID) }
            }
            // A reply can precede the inventory delta. Keep the operation pending
            // until its exact created ID is available, preventing duplicate opens.
            if self.isAvailable(surfaceID) { self.pendingSidebarPinOpenings.remove(id) }
            self.restorePinnedDesktopLayout(workspace: destination)
            self.scheduleRefresh()
        }, completion: { [weak self] reply in
            if reply != .issued { self?.pendingSidebarPinOpenings.remove(id) }
        })
        if result != .issued { pendingSidebarPinOpenings.remove(id) }
        return result
    }

    func movePinnedBrowserTab(_ id: UUID, to workspace: String) {
        guard let destination = Workspace.existing(byName: workspace) else { return }
        movePin(id, to: destination.projectId)
    }

    /// Keep pins with their live pages when a shared group moves to another space.
    /// A closed page keeps its saved shortcut; it is absent from the layout tree.
    func syncSidebarPins() {
        var removed: [UUID] = []
        var changedOwnership = false
        for index in browserSidebarPins.indices {
            guard let id = browserSidebarPins[index].surfaceID else { continue }
            if let record = owner(of: id)?.inventory.tabs[id], record.url == browserSidebarPins[index].url,
               let icon = record.iconPNGBase64 { browserSidebarPins[index].iconPNGBase64 = icon }
            if let workspace = workspaceName(for: id), workspace != browserSidebarPins[index].workspaceName {
                if pinnedDesktops.contains(where: { $0.workspaceName == workspace }) {
                    browserSidebarPins[index].workspaceName = workspace
                    changedOwnership = true
                } else if let group = spacePinnedGroups.first(where: { $0.workspaceName == workspace }) {
                    browserSidebarPins[index].workspaceName = group.workspaceName
                    removePinOrder(browserSidebarPins[index].id)
                    appendPinOrder(browserSidebarPins[index].id, workspace: workspace)
                } else { removed.append(browserSidebarPins[index].id) }
            }
        }
        for index in nativeAppSidebarPins.indices {
            guard let id = nativeAppSidebarPins[index].surfaceID else { continue }
            guard let window = Window.get(bySurfaceID: id) else {
                if !isAwaitingNativePinBinding(id) { nativeAppSidebarPins[index].surfaceID = nil }
                continue
            }
            if let workspace = window.nodeWorkspace?.name, workspace != nativeAppSidebarPins[index].workspaceName {
                if pinnedDesktops.contains(where: { $0.workspaceName == workspace }) {
                    nativeAppSidebarPins[index].workspaceName = workspace
                    changedOwnership = true
                } else { removed.append(nativeAppSidebarPins[index].id) }
            }
        }
        for id in removed {
            removePinOrder(id)
            browserSidebarPins.removeAll { $0.id == id }
            nativeAppSidebarPins.removeAll { $0.id == id }
            pendingSidebarPinOpenings.remove(id)
            pendingNativePinLaunches.removeValue(forKey: id)
        }
        if changedOwnership || !removed.isEmpty {
            prunePinnedMembers()
            for index in pinnedDesktops.indices {
                let workspace = pinnedDesktops[index].workspaceName
                let owned = browserSidebarPins.filter { $0.workspaceName == workspace }.map(\.id) +
                    nativeAppSidebarPins.filter { $0.workspaceName == workspace }.map(\.id)
                let added = Set(owned).subtracting(pinnedDesktops[index].memberIDs)
                guard !added.isEmpty else { continue }
                pinnedDesktops[index].memberIDs += owned.filter { added.contains($0) }
                pinnedDesktops[index].kind = .group
                // Keep closed slots while recording the newly joined members.
                // A complete live group is captured with its current layout below.
                let bindings = pinBindings(in: workspace)
                pinnedDesktops[index].layout += owned.filter { added.contains($0) }.map { member in
                    bindings[member].flatMap { PinnedLayoutNode.capture(.surface($0), tree: surfaceTree, members: [$0: member]) }
                        ?? .member(member, 1)
                }
            }
            capturePinnedLayouts()
        }
    }

    func browserPinDidClose(_ surfaceID: SurfaceID) {
        capturePinnedLayouts()
        for index in browserSidebarPins.indices where browserSidebarPins[index].surfaceID == surfaceID {
            pendingSidebarPinOpenings.remove(browserSidebarPins[index].id)
            browserSidebarPins[index].surfaceID = nil
        }
        unresolvedSidebarPinOwners.removeValue(forKey: surfaceID)
    }

    func reconcileSidebarPinInventory(_ inventory: BrowserInventory, full: Bool, connection: UUID) -> Set<SurfaceID> {
        var absent: Set<SurfaceID> = []
        let profiles = Set(inventory.tabs.keys.compactMap { id -> UUID? in
            if case .browserTab(let profile, _) = id { return profile }
            return nil
        })
        for pin in browserSidebarPins {
            guard let surfaceID = pin.surfaceID else { continue }
            if inventory.tabs[surfaceID] != nil {
                pendingSidebarPinOpenings.remove(pin.id)
                unresolvedSidebarPinOwners.removeValue(forKey: surfaceID)
            } else if full && owner(of: surfaceID) == nil &&
                        (unresolvedSidebarPinOwners[surfaceID] == connection ||
                            (unresolvedSidebarPinOwners[surfaceID] == nil && !pendingSidebarPinOpenings.contains(pin.id) && profiles.contains(pin.profileID))) {
                absent.insert(surfaceID)
                browserPinDidClose(surfaceID)
            }
        }
        return absent
    }

    func pinnedBrowserRows(in workspace: String) -> [WorkspaceSidebarItemViewModel] {
        syncSidebarPins()
        return browserSidebarPins.filter { $0.workspaceName == workspace }.map { pin in
            let record = pin.surfaceID.flatMap { owner(of: $0)?.inventory.tabs[$0] }
            return .init(kind: .pinnedBrowserTab(.init(pin: pin,
                title: record.flatMap { $0.title.isEmpty ? nil : $0.title } ?? pin.title,
                isFocused: pin.surfaceID.map { focusCoordinator.target == $0 && record != nil } ?? false,
                isOpen: record != nil)))
        }
    }
}
