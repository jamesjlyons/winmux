import AppKit
import Common
import WorkspaceCore

extension BrowserWorkspaceController {
    func pinWorkspaceName(_ id: UUID) -> String? {
        pinnedDesktops.first { $0.id == id }?.workspaceName ?? savedPinnedView(id)?.workspace ?? browserSidebarPins.first { $0.id == id }?.workspaceName ?? nativeAppSidebarPins.first { $0.id == id }?.workspaceName
    }

    func pinnedGroup(for space: WorkspaceProjectId, source: Workspace? = nil) -> Workspace {
        let regular = [focus.workspace, source].compactMap { $0 }.first { $0.projectId == space && !$0.isPinnedGroup }
            ?? projectWorkspaces(projectId: space).first { !$0.isPinnedGroup && !$0.isArchived && $0.isVisible }
        if let saved = spacePinnedGroups.first(where: { $0.spaceID == space.rawValue }) {
            let group = Workspace.get(byName: saved.workspaceName)
            group.assignProject(space)
            group.isPinnedGroup = true
            group.lifecycle = .durable
            if saved.lastRegularWorkspaceName == nil, let regular { rememberRegularWorkspace(regular) }
            return group
        }
        let name = "__space_pins_" + UUID().uuidString.lowercased()
        spacePinnedGroups.append(.init(spaceID: space.rawValue, workspaceName: name,
            lastRegularWorkspaceName: regular?.name))
        let group = Workspace.get(byName: name)
        group.assignProject(space)
        group.isPinnedGroup = true
        group.lifecycle = .durable
        group.seedMonitorIfNeeded(regular?.workspaceMonitor ?? source?.workspaceMonitor ?? mainMonitor)
        if var project = winMuxWorkspaceState.projectsById[space] {
            project.workspaceOrder.removeAll { $0 == group.id }
            project.workspaceOrder.insert(group.id, at: 0)
            winMuxWorkspaceState.registerProject(project)
        }
        return group
    }

    func restorePinnedGroups() {
        for saved in spacePinnedGroups {
            let space = WorkspaceProjectId(saved.spaceID)
            guard winMuxWorkspaceState.projectsById[space] != nil else { continue }
            let group = Workspace.get(byName: saved.workspaceName)
            group.assignProject(space)
            group.isPinnedGroup = true
            group.lifecycle = .durable
        }
    }

    func migrateSidebarPinsToSpaceGroups() { migratePinnedDesktops() }

    func appendPinOrder(_ id: UUID, workspace: String) {
        guard let index = spacePinnedGroups.firstIndex(where: { $0.workspaceName == workspace }) else { return }
        if !spacePinnedGroups[index].pinOrder.contains(id) { spacePinnedGroups[index].pinOrder.append(id) }
    }

    func removePinOrder(_ id: UUID) {
        for index in spacePinnedGroups.indices { spacePinnedGroups[index].pinOrder.removeAll { $0 == id } }
    }

    func rememberRegularWorkspace(_ workspace: Workspace) {
        guard !workspace.isPinnedGroup, !workspace.isIncognito else { return }
        ensurePinShelf(workspace.projectId, source: workspace)
        if let shelf = pinShelves.firstIndex(where: { $0.spaceID == workspace.projectId.rawValue }) {
            pinShelves[shelf].lastRegularWorkspaceName = workspace.name
        }
        guard let index = spacePinnedGroups.firstIndex(where: { $0.spaceID == workspace.projectId.rawValue }) else { return }
        spacePinnedGroups[index].lastRegularWorkspaceName = workspace.name
    }

    func regularWorkspaceForNewItem(_ workspace: Workspace) -> Workspace {
        guard workspace.isPinnedGroup else { return workspace }
        if let name = pinShelves.first(where: { $0.spaceID == workspace.projectId.rawValue })?.lastRegularWorkspaceName
            ?? spacePinnedGroups.first(where: { $0.spaceID == workspace.projectId.rawValue })?.lastRegularWorkspaceName,
           let remembered = Workspace.existing(byName: name), remembered.projectId == workspace.projectId,
           !remembered.isPinnedGroup, !remembered.isArchived,
           workspaceIsAvailableForMonitor(remembered, monitor: workspace.workspaceMonitor) { return remembered }
        if let regular = projectWorkspaces(projectId: workspace.projectId).first(where: {
            !$0.isPinnedGroup && !$0.isArchived && workspaceIsAvailableForMonitor($0, monitor: workspace.workspaceMonitor)
        }) { return regular }
        return createBlankWorkspace(projectId: workspace.projectId, monitor: workspace.workspaceMonitor)
    }

    func hasPins(in workspace: String) -> Bool {
        pinnedDesktops.contains { $0.workspaceName == workspace } || browserSidebarPins.contains { $0.workspaceName == workspace } || nativeAppSidebarPins.contains { $0.workspaceName == workspace }
    }

    func canAdoptNativePinWindow(_ window: Window) -> Bool {
        guard usesSurfaceTree, window.nodeWorkspace?.isArchived == false, window.toLiveFocusOrNil() != nil,
              case .standard = window.layoutReason else { return false }
        return true
    }

    @discardableResult
    func legacyPinSurface(_ surface: SurfaceID, in space: WorkspaceProjectId? = nil) -> Bool {
        guard usesSurfaceTree, !isPrivateSurface(surface), space?.isIncognito != true, let sourceName = workspaceName(for: surface), let source = Workspace.existing(byName: sourceName), !source.isIncognito else { return false }
        let destination = pinnedGroup(for: space ?? source.projectId, source: source)
        if let existing = pinID(for: surface) {
            return pinWorkspaceName(existing) == destination.name || movePin(existing, to: destination.projectId)
        }
        if case .browserTab = surface {
            guard pinBrowserTab(surface) else { return false }
            if let pin = sidebarPin(for: surface), pin.workspaceName != destination.name { movePin(pin.id, to: destination.projectId) }
            return true
        }
        guard let window = Window.get(bySurfaceID: surface), let bundle = window.app.rawAppBundleId,
              let path = window.app.bundlePath, !bundle.isEmpty,
              canAdoptNativePinWindow(window),
              browserSidebarPins.count + nativeAppSidebarPins.count < 10000 else { return false }
        let wasFocused = focus.windowOrNil?.surfaceID == surface || focusCoordinator.target == surface
        if let existing = nativeAppSidebarPins.first(where: { $0.workspaceName == destination.name && $0.bundleIdentifier == bundle && !isGroupedPin($0.id) }) {
            guard adoptAppWindow(window, pinID: existing.id) else { return false }
            if wasFocused { _ = select(surface) }
            scheduleRefresh()
            return true
        }
        let pin = NativeAppSidebarPin(workspaceName: destination.name, bundleIdentifier: bundle,
            bundlePath: path, title: window.app.name ?? bundle, surfaceID: surface)
        guard pin.isValid else { return false }
        nativeAppSidebarPins.append(pin)
        appendPinOrder(pin.id, workspace: destination.name)
        guard adoptAppWindow(window, pinID: pin.id) else {
            nativeAppSidebarPins.removeAll { $0.id == pin.id }
            removePinOrder(pin.id)
            return false
        }
        if wasFocused { _ = select(surface) }
        scheduleRefresh()
        return true
    }

    @discardableResult
    func adoptAppWindow(_ window: Window, pinID: UUID) -> Bool {
        guard let index = nativeAppSidebarPins.firstIndex(where: { $0.id == pinID }),
              window.app.rawAppBundleId == nativeAppSidebarPins[index].bundleIdentifier,
              let group = Workspace.existing(byName: nativeAppSidebarPins[index].workspaceName),
              window.nodeWorkspace == group || canAdoptNativePinWindow(window) else { return false }
        if let previous = nativeAppSidebarPins[index].surfaceID, previous != window.surfaceID, isAvailable(previous) {
            let destination = config.workspaceInteractionMode == .views ? newStandaloneWorkspace(in: group) : regularWorkspaceForNewItem(group)
            guard adoptPinnedSurface(previous, into: destination.name) else { return false }
        }
        if let previous = nativeAppSidebarPins[index].surfaceID, previous != window.surfaceID, !isAvailable(previous) {
            retireMissingNativePinBinding(previous)
        }
        guard adoptPinnedSurface(window.surfaceID, into: group.name) else { return false }
        for other in nativeAppSidebarPins.indices where nativeAppSidebarPins[other].id != pinID && nativeAppSidebarPins[other].surfaceID == window.surfaceID {
            nativeAppSidebarPins[other].surfaceID = nil
        }
        nativeAppSidebarPins[index].surfaceID = window.surfaceID
        restorePinnedViewLayout(containing: pinID)
        return true
    }

    @discardableResult
    func legacyUnpin(_ id: UUID, to destination: Workspace? = nil) -> Bool {
        if savedPinnedView(id) != nil { return unpinViewGroup(id, to: destination) }
        let browser = browserSidebarPins.first { $0.id == id }
        let app = nativeAppSidebarPins.first { $0.id == id }
        let workspace = browser?.workspaceName ?? app?.workspaceName
        let live = browser?.surfaceID ?? app?.surfaceID
        let wasFocused = live != nil && (focusCoordinator.target == live || focus.windowOrNil?.surfaceID == live)
        guard let workspace else { return false }
        if let live, let group = Workspace.existing(byName: workspace) {
            let target = destination ?? (config.workspaceInteractionMode == .views ? newStandaloneWorkspace(in: group) : regularWorkspaceForNewItem(group))
            guard !target.isPinnedGroup else { return false }
            if case .browserTab = live {
                guard adoptPinnedSurface(live, into: target.name) else { return false }
            } else if isAvailable(live) {
                guard adoptPinnedSurface(live, into: target.name) else { return false }
            } else { retireMissingNativePinBinding(live) }
        }
        detachPinFromSavedGroup(id)
        removePinOrder(id)
        pendingNativePinLaunches.removeValue(forKey: id)
        failedNativePinLaunches.remove(id)
        nativeAppSidebarPins.removeAll { $0.id == id }
        browserSidebarPins.removeAll { $0.id == id }
        pendingSidebarPinOpenings.remove(id)
        if let live { unresolvedSidebarPinOwners.removeValue(forKey: live) }
        if wasFocused, let live, isAvailable(live) { _ = select(live) }
        scheduleRefresh()
        return true
    }

    @discardableResult
    func legacyMovePin(_ id: UUID, to space: WorkspaceProjectId) -> Bool {
        if savedPinnedView(id) != nil { return movePinnedViewGroup(id, to: space) }
        guard !space.isIncognito, winMuxWorkspaceState.projectsById[space] != nil else { return false }
        let sourceName = pinWorkspaceName(id)
        let destination = pinnedGroup(for: space)
        if let pin = browserSidebarPins.first(where: { $0.id == id }),
           let accepted = moveUsingDestinationProfile(pin.surfaceID.map { [$0] } ?? [],
                closedPin: pin.surfaceID == nil ? pin : nil, to: destination, commit: { [weak self] in
                    self?.movePin(id, to: space) ?? false
                }) { return accepted }
        var live: SurfaceID?
        if let index = browserSidebarPins.firstIndex(where: { $0.id == id }) {
            live = browserSidebarPins[index].surfaceID
            if let live, !adoptPinnedSurface(live, into: destination.name) { return false }
            browserSidebarPins[index].workspaceName = destination.name
        } else if let index = nativeAppSidebarPins.firstIndex(where: { $0.id == id }) {
            let bundle = nativeAppSidebarPins[index].bundleIdentifier
            guard !nativeAppSidebarPins.contains(where: { $0.id != id && $0.workspaceName == destination.name && $0.bundleIdentifier == bundle && !isGroupedPin($0.id) }) else { return false }
            live = nativeAppSidebarPins[index].surfaceID
            if let live, isAvailable(live), !adoptPinnedSurface(live, into: destination.name) { return false }
            if let live, !isAvailable(live) {
                retireMissingNativePinBinding(live)
                nativeAppSidebarPins[index].surfaceID = nil
            }
            nativeAppSidebarPins[index].workspaceName = destination.name
        } else { return false }
        detachPinFromSavedGroup(id)
        removePinOrder(id)
        appendPinOrder(id, workspace: destination.name)
        if let live, focusCoordinator.target == live, sourceName != destination.name,
           let sourceName, let source = Workspace.existing(byName: sourceName), focus.workspace == source {
            if let remaining = preferredSurface(in: source) { _ = select(remaining) }
            else { _ = source.focusWorkspace(restoringSurfaceSelection: false); nativeSelectionChanged(nil) }
        }
        scheduleRefresh()
        return true
    }

    func legacyReorderPin(_ id: UUID, before target: UUID) {
        guard id != target, let workspace = pinWorkspaceName(id), workspace == pinWorkspaceName(target),
              let index = spacePinnedGroups.firstIndex(where: { $0.workspaceName == workspace }) else { return }
        let members = savedPinnedView(id).map { Set($0.view.members.values) } ?? [id]
        let targets = savedPinnedView(target).map { Set($0.view.members.values) } ?? [target]
        let moved = spacePinnedGroups[index].pinOrder.filter { members.contains($0) }
        spacePinnedGroups[index].pinOrder.removeAll { members.contains($0) }
        if let at = spacePinnedGroups[index].pinOrder.firstIndex(where: { targets.contains($0) }) {
            spacePinnedGroups[index].pinOrder.insert(contentsOf: moved, at: at)
        } else { spacePinnedGroups[index].pinOrder += moved }
        scheduleRefresh()
    }

    func legacyDiscardPins(in space: WorkspaceProjectId) {
        let groups = spacePinnedGroups.filter { $0.spaceID == space.rawValue }
        let names = Set(groups.map(\.workspaceName))
        let ids = browserSidebarPins.filter { names.contains($0.workspaceName) }.map(\.id)
            + nativeAppSidebarPins.filter { names.contains($0.workspaceName) }.map(\.id)
        for id in ids { _ = unpin(id) }
        spacePinnedGroups.removeAll { $0.spaceID == space.rawValue }
        scheduleRefresh()
    }

    func legacyMovePins(in space: WorkspaceProjectId, to destination: WorkspaceProjectId) {
        guard let source = spacePinnedGroups.first(where: { $0.spaceID == space.rawValue }) else { return }
        for id in pinTileOrder(in: source.workspaceName) {
            if !movePin(id, to: destination) {
                let regular = regularWorkspaceForNewItem(pinnedGroup(for: destination))
                _ = unpin(id, to: regular)
            }
        }
    }

    func appBundleURL(for pin: NativeAppSidebarPin) -> URL? {
        let saved = URL(fileURLWithPath: pin.bundlePath)
        if Bundle(url: saved)?.bundleIdentifier == pin.bundleIdentifier { return saved }
        guard let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pin.bundleIdentifier),
              Bundle(url: found)?.bundleIdentifier == pin.bundleIdentifier else { return nil }
        return found
    }

    func appWindow(for pin: NativeAppSidebarPin) -> Window? {
        guard let id = pin.surfaceID, let window = Window.get(bySurfaceID: id),
              window.app.rawAppBundleId == pin.bundleIdentifier, window.toLiveFocusOrNil() != nil else { return nil }
        return window
    }

    @discardableResult
    func legacySelectPin(_ id: UUID, selectAfterOpening: Bool = true) -> SurfaceActionOutcome {
        if let saved = savedPinnedView(id) {
            let members = saved.view.template.group(id)?.surfaces.compactMap { saved.view.members[$0] } ?? []
            let live = livePinSurfaces()
            let selected = preferredSurface(in: Workspace.get(byName: saved.workspace))
            var issued = false
            for member in members where live[member] == nil { if selectPin(member) == .issued { issued = true } }
            restorePinnedViewLayout(containing: members.first)
            let target = selected.flatMap { candidate in members.contains { live[$0] == candidate } ? candidate : nil } ?? saved.view.template.activeSurfaces[id].flatMap { saved.view.members[$0] }.flatMap { live[$0] }
                ?? members.compactMap { live[$0] }.first
            if let target { return select(target) }
            return issued ? .issued : .unavailable
        }
        if browserSidebarPins.contains(where: { $0.id == id }) { return selectPinnedBrowserTab(id, selectAfterOpening: selectAfterOpening) }
        guard let pin = nativeAppSidebarPins.first(where: { $0.id == id }) else { return .unavailable }
        if let window = appWindow(for: pin) {
            guard adoptAppWindow(window, pinID: id) else { return .unavailable }
            return select(window.surfaceID)
        }
        guard pendingNativePinLaunches[id] == nil else { return .issued }
        guard let url = appBundleURL(for: pin) else { failedNativePinLaunches.insert(id); scheduleRefresh(); return .unavailable }
        if selectAfterOpening { _ = Workspace.existing(byName: pin.workspaceName)?.focusWorkspace() }
        let existingWindows = Set(MacWindow.allWindows.map(\.surfaceID))
        let operation = UUID(), generation = focusCoordinator.generation
        pendingNativePinLaunches[id] = operation
        failedNativePinLaunches.remove(id)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                guard let self, self.pendingNativePinLaunches[id] == operation else { return }
                if error != nil {
                    self.pendingNativePinLaunches.removeValue(forKey: id)
                    self.failedNativePinLaunches.insert(id)
                    self.scheduleRefresh()
                    return
                }
                for _ in 0..<75 {
                    guard self.pendingNativePinLaunches[id] == operation,
                          let current = self.nativeAppSidebarPins.first(where: { $0.id == id }) else { return }
                    if let window = MacWindow.allWindows.first(where: { candidate in !existingWindows.contains(candidate.surfaceID) && candidate.app.rawAppBundleId == current.bundleIdentifier && self.canAdoptNativePinWindow(candidate) && !self.nativeAppSidebarPins.contains(where: { pin in pin.id != id && pin.surfaceID == candidate.surfaceID }) }) {
                        guard self.adoptAppWindow(window, pinID: id) else { break }
                        self.restorePinnedDesktopLayout(workspace: current.workspaceName)
                        self.pendingNativePinLaunches.removeValue(forKey: id)
                        if selectAfterOpening && self.focusCoordinator.generation == generation { _ = self.select(window.surfaceID) }
                        self.scheduleRefresh()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                self.pendingNativePinLaunches.removeValue(forKey: id)
                self.failedNativePinLaunches.insert(id)
                self.scheduleRefresh()
            }
        }
        scheduleRefresh()
        return .issued
    }

    func legacyPinTiles(in workspace: String) -> [WorkspaceSidebarPinViewModel] {
        syncSidebarPins()
        return makeMemberPinTiles(in: workspace,
            browserPins: browserSidebarPins.filter { $0.workspaceName == workspace },
            nativePins: nativeAppSidebarPins.filter { $0.workspaceName == workspace })
    }

    /// A sidebar refresh covers every workspace. Reconcile and partition the pins
    /// once so ordinary groups do not each scan every pin in every space.
    func legacyPinTilesByWorkspace() -> [String: [WorkspaceSidebarPinViewModel]] {
        syncSidebarPins()
        let browser = Dictionary(grouping: browserSidebarPins, by: \.workspaceName)
        let native = Dictionary(grouping: nativeAppSidebarPins, by: \.workspaceName)
        return Dictionary(uniqueKeysWithValues: Set(browser.keys).union(native.keys).map { workspace in
            (workspace, makeMemberPinTiles(in: workspace, browserPins: browser[workspace] ?? [], nativePins: native[workspace] ?? []))
        })
    }

    func makeMemberPinTiles(in workspace: String, browserPins: [BrowserSidebarPin], nativePins: [NativeAppSidebarPin]) -> [WorkspaceSidebarPinViewModel] {
        var tiles = browserPins.map { pin in
            let record = pin.surfaceID.flatMap { owner(of: $0)?.inventory.tabs[$0] }
            return WorkspaceSidebarPinViewModel(id: pin.id, workspaceName: workspace, title: record?.title ?? pin.title,
                bundleIdentifier: nil, bundlePath: nil, iconPNGBase64: record != nil ? record?.iconPNGBase64 : pin.iconPNGBase64,
                surfaceID: pin.surfaceID, isFocused: pin.surfaceID.map { focusCoordinator.target == $0 && record != nil } ?? false,
                isOpen: record != nil, isLoading: pendingSidebarPinOpenings.contains(pin.id), isUnavailable: false, isBrowser: true, url: pin.url)
        }
        tiles += nativePins.map { pin in
            let window = pin.surfaceID.flatMap { Window.get(bySurfaceID: $0) }
            return WorkspaceSidebarPinViewModel(id: pin.id, workspaceName: workspace, title: pin.title,
                bundleIdentifier: pin.bundleIdentifier, bundlePath: pin.bundlePath, iconPNGBase64: nil,
                surfaceID: window?.surfaceID, isFocused: window.map { focusCoordinator.target == $0.surfaceID || focus.windowOrNil?.surfaceID == $0.surfaceID } ?? false,
                isOpen: window != nil, isLoading: pendingNativePinLaunches[pin.id] != nil,
                isUnavailable: failedNativePinLaunches.contains(pin.id) || appBundleURL(for: pin) == nil, isBrowser: false)
        }
        let order = pinTileOrder(in: workspace)
        let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        tiles = groupedPinTiles(tiles, in: workspace)
        return tiles.sorted { (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max) }
    }
}
