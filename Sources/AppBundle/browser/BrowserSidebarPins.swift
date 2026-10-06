import AppKit
import WorkspaceCore

extension BrowserWorkspaceController {
    func sidebarPin(for surfaceID: SurfaceID) -> BrowserSidebarPin? {
        browserSidebarPins.first { $0.surfaceID == surfaceID }
    }

    @discardableResult
    func pinBrowserTab(_ surfaceID: SurfaceID) -> Bool {
        guard usesSurfaceTree, !isPrivateSurface(surfaceID), browserSidebarPins.count + nativeAppSidebarPins.count < 10_000,
              sidebarPin(for: surfaceID) == nil,
              let record = owner(of: surfaceID)?.inventory.tabs[surfaceID],
              let workspace = workspaceName(for: surfaceID) else { return false }
        guard case .browserTab(let profile, _) = surfaceID else { return false }
        guard let source = Workspace.existing(byName: workspace) else { return false }
        let wasFocused = focusCoordinator.target == surfaceID || (record.focused && focus.workspace == source)
        let group = pinnedGroup(for: source.projectId, source: source)
        let pin = BrowserSidebarPin(profileID: profile, workspaceName: group.name,
                                   title: record.title.isEmpty ? "New tab" : record.title,
                                   url: record.url.isEmpty ? "chrome://newtab/" : record.url,
                                   surfaceID: surfaceID, iconPNGBase64: record.iconPNGBase64)
        guard pin.isValid else { return false }
        browserSidebarPins.append(pin)
        appendPinOrder(pin.id, workspace: group.name)
        adoptPinnedSurface(surfaceID, into: group.name)
        if wasFocused { _ = select(surfaceID) }
        scheduleRefresh()
        return true
    }

    func unpinBrowserTab(_ id: UUID) { unpin(id) }

    @discardableResult
    func selectPinnedBrowserTab(_ id: UUID) -> SurfaceActionOutcome {
        guard let pin = browserSidebarPins.first(where: { $0.id == id }) else { return .unavailable }
        if let surfaceID = pin.surfaceID, isAvailable(surfaceID) { return select(surfaceID) }
        // A lost helper connection is not confirmation that a live page closed.
        if let surfaceID = pin.surfaceID, unresolvedSidebarPinOwners[surfaceID] != nil { return .unavailable }
        guard pendingSidebarPinOpenings.insert(id).inserted else { return .issued }
        let result = openBrowserTab(url: pin.url, workspaceName: pin.workspaceName, profileID: pin.profileID, explicitPlacement: true, created: { [weak self] surfaceID in
            guard let self else { return }
            guard let index = self.browserSidebarPins.firstIndex(where: { $0.id == id }) else {
                if let group = Workspace.existing(byName: pin.workspaceName) {
                    let destination = config.workspaceInteractionMode == .views
                        ? self.newStandaloneWorkspace(in: group) : self.regularWorkspaceForNewItem(group)
                    _ = self.adoptPinnedSurface(surfaceID, into: destination.name)
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
            self.restorePinnedViewLayout(containing: id)
            // A reply can precede the inventory delta. Keep the operation pending
            // until its exact created ID is available, preventing duplicate opens.
            if self.isAvailable(surfaceID) { self.pendingSidebarPinOpenings.remove(id) }
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
        for index in browserSidebarPins.indices {
            guard let id = browserSidebarPins[index].surfaceID else { continue }
            if let record = owner(of: id)?.inventory.tabs[id], record.url == browserSidebarPins[index].url,
               let icon = record.iconPNGBase64 { browserSidebarPins[index].iconPNGBase64 = icon }
            if let workspace = workspaceName(for: id), workspace != browserSidebarPins[index].workspaceName {
                if let group = spacePinnedGroups.first(where: { $0.workspaceName == workspace }) {
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
                removed.append(nativeAppSidebarPins[index].id)
            }
        }
        for id in removed {
            detachPinFromSavedGroup(id)
            removePinOrder(id)
            browserSidebarPins.removeAll { $0.id == id }
            nativeAppSidebarPins.removeAll { $0.id == id }
            pendingSidebarPinOpenings.remove(id)
            pendingNativePinLaunches.removeValue(forKey: id)
        }
        syncPinnedViewGroups()
    }

    func browserPinDidClose(_ surfaceID: SurfaceID) {
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
