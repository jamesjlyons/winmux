import AppKit
import Common
import WorkspaceCore

extension BrowserWorkspaceController {
    func savedPinnedView(_ id: UUID) -> (workspace: String, view: PinnedViewGroup)? {
        for group in spacePinnedGroups {
            if let view = group.views.first(where: { $0.id == id }) { return (group.workspaceName, view) }
        }
        return nil
    }

    func isGroupedPin(_ id: UUID) -> Bool { spacePinnedGroups.contains { $0.views.contains { $0.members.values.contains(id) } } }

    func canCombinePinnedView(containing surface: SurfaceID) -> Bool {
        if let desktop = pinnedDesktops.first(where: { $0.workspaceName == workspaceName(for: surface) }) {
            let live = livePinSurfaces()
            return desktop.memberIDs.allSatisfy { live[$0] != nil }
        }
        guard let pin = pinID(for: surface), let view = spacePinnedGroups.flatMap(\.views).first(where: { $0.members.values.contains(pin) }) else { return true }
        let live = livePinSurfaces()
        return view.members.values.allSatisfy { live[$0] != nil }
    }

    func pinID(for surface: SurfaceID) -> UUID? {
        browserSidebarPins.first { $0.surfaceID == surface }?.id ?? nativeAppSidebarPins.first { $0.surfaceID == surface }?.id
    }

    func livePinSurfaces() -> [UUID: SurfaceID] {
        var result: [UUID: SurfaceID] = [:]
        for pin in browserSidebarPins { if let id = pin.surfaceID, isAvailable(id) { result[pin.id] = id } }
        for pin in nativeAppSidebarPins { if let id = pin.surfaceID, isAvailable(id) { result[pin.id] = id } }
        return result
    }

    private func savedArrangement(_ node: SurfaceTreeNode, in workspace: String, title: String) -> PinnedViewGroup? {
        guard case .group(let id, _) = node else { return nil }
        var members: [SurfaceID: UUID] = [:]
        for surface in node.surfaces {
            guard let pin = pinID(for: surface) else { return nil }
            members[surface] = pin
        }
        var template = SurfaceTree()
        template.reconcile(node.surfaces, in: workspace)
        guard template.importOrganization([node], in: workspace, layouts: surfaceTree.layouts,
            activeSurfaces: surfaceTree.activeSurfaces, weights: surfaceTree.weights) else { return nil }
        return .init(id: id, title: title, template: template, members: members)
    }

    /// Capture only complete arrangements. A closed member must not erase the
    /// saved layout; a reopened member is rebound using its stable pin ID.
    func syncPinnedViewGroups() {
        let live = livePinSurfaces()
        for group in spacePinnedGroups {
            for view in group.views {
                if let changed = view.members.first(where: { old, pin in
                    live[pin].map { $0 != old } ?? false
                }) { restorePinnedViewLayout(containing: changed.value) }
            }
        }
        for index in spacePinnedGroups.indices {
            let workspace = spacePinnedGroups[index].workspaceName
            for node in surfaceTree.roots[workspace] ?? [] {
                guard case .group(let id, _) = node else { continue }
                let existing = spacePinnedGroups[index].views.first { $0.id == id }
                guard let saved = savedArrangement(node, in: workspace, title: existing?.title ?? "Pinned Group") else { continue }
                if let existing, !Set(existing.members.values).isSubset(of: Set(saved.members.values)) { continue }
                // Incomplete saved groups retain their closed members.
                if spacePinnedGroups[index].views.contains(where: {
                    $0.id != id && !Set($0.members.values).isDisjoint(with: saved.members.values) &&
                    !Set($0.members.values).isSubset(of: Set(saved.members.values))
                }) { continue }
                spacePinnedGroups[index].views.removeAll { !Set($0.members.values).isDisjoint(with: saved.members.values) }
                spacePinnedGroups[index].views.append(saved)
            }
        }
    }

    func restorePinnedViewLayout(containing pin: UUID?) {
        if let pin, let desktop = pinnedDesktops.first(where: { $0.memberIDs.contains(pin) }) {
            restorePinnedDesktopLayout(workspace: desktop.workspaceName)
            return
        }
        guard let pin, let space = spacePinnedGroups.first(where: { $0.views.contains { $0.members.values.contains(pin) } }),
              let view = space.views.first(where: { $0.members.values.contains(pin) }) else { return }
        let live = livePinSurfaces().filter { view.members.values.contains($0.key) && workspaceName(for: $0.value) == space.workspaceName }
        let template = view.layout(using: live, in: space.workspaceName)
        guard let nodes = template.roots[space.workspaceName], nodes.count == 1,
              case .group = nodes[0] else { return }
        var candidate = surfaceTree
        candidate.reconcile((candidate.roots[space.workspaceName] ?? []).flatMap(\.surfaces) + Array(live.values), in: space.workspaceName)
        for id in nodes.flatMap(\.surfaces) { _ = candidate.moveToRoot(id, in: space.workspaceName) }
        guard candidate.importOrganization(nodes, in: space.workspaceName, layouts: template.layouts,
            activeSurfaces: template.activeSurfaces, weights: template.weights) else { return }
        if let selected = focusCoordinator.target { candidate.select(selected) }
        surfaceTree = candidate
        mixedLayoutWorkspaces.insert(space.workspaceName)
    }

    func detachPinFromSavedGroup(_ pin: UUID) {
        for index in spacePinnedGroups.indices {
            for viewIndex in spacePinnedGroups[index].views.indices {
                let ids = spacePinnedGroups[index].views[viewIndex].members.filter { $0.value == pin }.map(\.key)
                for id in ids {
                    spacePinnedGroups[index].views[viewIndex].members.removeValue(forKey: id)
                    spacePinnedGroups[index].views[viewIndex].template.remove(id)
                }
            }
            let workspace = spacePinnedGroups[index].workspaceName
            spacePinnedGroups[index].views.removeAll { !$0.isValid(in: workspace) }
        }
    }

    @discardableResult
    func legacyPinSurfaceGroup(_ id: UUID, in space: WorkspaceProjectId? = nil) -> Bool {
        guard canMoveGroup(id), let node = surfaceTree.group(id),
              let source = workspaceName(forGroup: id).flatMap({ Workspace.existing(byName: $0) }),
              !source.isIncognito, space?.isIncognito != true, !node.surfaces.contains(where: isPrivateSurface),
              node.surfaces.allSatisfy({ pinID(for: $0) == nil }),
              browserSidebarPins.count + nativeAppSidebarPins.count + node.surfaces.count <= 10000 else { return false }
        let destination = pinnedGroup(for: space ?? source.projectId, source: source)
        if let accepted = moveUsingDestinationProfile(node.surfaces, to: destination, commit: { [weak self] in
            self?.legacyPinSurfaceGroup(id, in: space) ?? false
        }) { return accepted }
        var browser: [BrowserSidebarPin] = [], apps: [NativeAppSidebarPin] = []
        for surface in node.surfaces {
            switch surface {
            case .browserTab(let profile, _):
                guard let record = owner(of: surface)?.inventory.tabs[surface] else { return false }
                let pin = BrowserSidebarPin(profileID: profile, workspaceName: destination.name,
                    title: record.title.isEmpty ? "New tab" : record.title, url: record.url.isEmpty ? "chrome://newtab/" : record.url,
                    surfaceID: surface, iconPNGBase64: record.iconPNGBase64)
                guard pin.isValid else { return false }; browser.append(pin)
            case .nativeWindow:
                guard let window = Window.get(bySurfaceID: surface), canAdoptNativePinWindow(window),
                      let bundle = window.app.rawAppBundleId, let path = window.app.bundlePath else { return false }
                let pin = NativeAppSidebarPin(workspaceName: destination.name, bundleIdentifier: bundle,
                    bundlePath: path, title: window.app.name ?? bundle, surfaceID: surface)
                guard pin.isValid else { return false }; apps.append(pin)
            }
        }
        let selected = focusCoordinator.target ?? focus.windowOrNil?.surfaceID
        // Move once: moving individual leaves would dissolve nested containers.
        guard moveGroup(id, to: destination) else { return false }
        browserSidebarPins += browser; nativeAppSidebarPins += apps
        for surface in node.surfaces { if let pin = pinID(for: surface) { appendPinOrder(pin, workspace: destination.name) } }
        if let moved = surfaceTree.group(id), let saved = savedArrangement(moved, in: destination.name, title: workspaceDefaultDisplayName(source.name)),
           let index = spacePinnedGroups.firstIndex(where: { $0.workspaceName == destination.name }) {
            spacePinnedGroups[index].views.append(saved)
        }
        if let selected, node.surfaces.contains(selected) { _ = select(selected) }
        scheduleRefresh()
        return true
    }

    @discardableResult
    func pinWorkspaceView(_ name: String) -> Bool {
        guard let source = Workspace.existing(byName: name), !source.isPinnedGroup, !source.isIncognito,
              let nodes = surfaceTree.roots[name], !nodes.isEmpty else { return false }
        if nodes.count == 1 {
            switch nodes[0] {
            case .surface(let surface): return pinSurface(surface)
            case .group(let id, _): return pinSurfaceGroup(id)
            }
        }
        let before = surfaceTree, id = UUID()
        // Ordinary multi-root views tile horizontally; preserve their weights.
        var candidate = SurfaceTree(); candidate.reconcile(nodes.flatMap(\.surfaces), in: name)
        var layouts = before.layouts; layouts[id] = .horizontal
        guard candidate.importOrganization([.group(id, nodes)], in: name, layouts: layouts,
            activeSurfaces: before.activeSurfaces, weights: before.weights) else { return false }
        for surface in nodes.flatMap(\.surfaces) { _ = surfaceTree.moveToRoot(surface, in: name) }
        guard surfaceTree.importOrganization(candidate.roots[name] ?? [], in: name, layouts: candidate.layouts,
            activeSurfaces: candidate.activeSurfaces, weights: candidate.weights) else { surfaceTree = before; return false }
        guard pinSurfaceGroup(id) else { surfaceTree = before; return false }
        return true
    }

    func pinTileOrder(in workspace: String) -> [UUID] {
        guard let space = spacePinnedGroups.first(where: { $0.workspaceName == workspace }) else { return [] }
        var seen: Set<UUID> = []
        return space.pinOrder.compactMap { pin in
            let id = space.views.first { $0.members.values.contains(pin) }?.id ?? pin
            return seen.insert(id).inserted ? id : nil
        }
    }

    func groupedPinTiles(_ tiles: [WorkspaceSidebarPinViewModel], in workspace: String) -> [WorkspaceSidebarPinViewModel] {
        guard let space = spacePinnedGroups.first(where: { $0.workspaceName == workspace }) else { return tiles }
        let grouped = Set(space.views.flatMap { $0.members.values })
        return tiles.filter { !grouped.contains($0.id) } + space.views.compactMap { view in
            let members = tiles.filter { view.members.values.contains($0.id) }
            guard !members.isEmpty else { return nil }
            let representative = members.first(where: \.isFocused) ?? members.first(where: \.isOpen) ?? members[0]
            return .init(id: view.id, workspaceName: workspace, title: view.title,
                bundleIdentifier: nil, bundlePath: nil, iconPNGBase64: nil, surfaceID: representative.surfaceID,
                isFocused: members.contains(where: \.isFocused), isOpen: members.contains(where: \.isOpen),
                isLoading: members.contains(where: \.isLoading), isUnavailable: members.allSatisfy(\.isUnavailable),
                isBrowser: false, members: members, isGroup: true, memberCount: members.count, groupMembers: members,
                isSelected: members.contains(where: \.isSelected))
        }
    }

    @discardableResult
    func unpinViewGroup(_ id: UUID, to destination: Workspace?) -> Bool {
        guard let saved = savedPinnedView(id), let source = Workspace.existing(byName: saved.workspace) else { return false }
        let live = livePinSurfaces().filter { saved.view.members.values.contains($0.key) }
        guard live.values.allSatisfy(canMoveSurface) else { return false }
        let target = destination ?? newStandaloneWorkspace(in: source)
        guard !target.isPinnedGroup, target.projectId == source.projectId else { return false }
        let selected = focusCoordinator.target
        restorePinnedViewLayout(containing: saved.view.members.values.first)
        if surfaceTree.group(id) != nil {
            guard moveGroup(id, to: target) else { return false }
        } else {
            for surface in live.values { guard adoptPinnedSurface(surface, into: target.name) else { return false } }
        }
        removePinnedView(id)
        for pin in saved.view.members.values { _ = unpin(pin, to: target) }
        if let selected, live.values.contains(selected) { _ = select(selected) }
        scheduleRefresh()
        return true
    }

    func removePinnedView(_ id: UUID) {
        for index in spacePinnedGroups.indices { spacePinnedGroups[index].views.removeAll { $0.id == id } }
    }

    @discardableResult
    func movePinnedViewGroup(_ id: UUID, to space: WorkspaceProjectId) -> Bool {
        guard !space.isIncognito, let saved = savedPinnedView(id),
              let source = Workspace.existing(byName: saved.workspace), source.projectId != space,
              winMuxWorkspaceState.projectsById[space] != nil else { return false }
        let live = livePinSurfaces().filter { saved.view.members.values.contains($0.key) }
        // Reopen the group before a cross-profile transfer so the existing
        // all-or-nothing profile transaction can validate every owner.
        guard live.count == saved.view.members.count else { return false }
        let destination = pinnedGroup(for: space)
        if let accepted = moveUsingDestinationProfile(Array(live.values), to: destination, commit: { [weak self] in
            self?.movePinnedViewGroup(id, to: space) ?? false
        }) { return accepted }
        guard moveGroup(id, to: destination) else { return false }
        removePinnedView(id)
        for pin in saved.view.members.values {
            removePinOrder(pin)
            if let index = browserSidebarPins.firstIndex(where: { $0.id == pin }) { browserSidebarPins[index].workspaceName = destination.name }
            if let index = nativeAppSidebarPins.firstIndex(where: { $0.id == pin }) { nativeAppSidebarPins[index].workspaceName = destination.name }
            appendPinOrder(pin, workspace: destination.name)
        }
        if let node = surfaceTree.group(id), let view = savedArrangement(node, in: destination.name, title: saved.view.title),
           let index = spacePinnedGroups.firstIndex(where: { $0.workspaceName == destination.name }) { spacePinnedGroups[index].views.append(view) }
        scheduleRefresh()
        return true
    }
}
