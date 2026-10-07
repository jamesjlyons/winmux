import AppKit
import Common
import WorkspaceCore

extension BrowserWorkspaceController {
    /// Allocation is restricted to arrival/explicit separation. General rebinding
    /// also runs during fullscreen and restore and must never allocate views.
    func newStandaloneWorkspace(in source: Workspace, excluding window: Window? = nil,
                                reserved: Set<String> = []) -> Workspace {
        let candidates = [source] + projectWorkspaces(projectId: source.projectId).filter { $0 !== source }
        let profileMoveDestinations = Set(pendingProfileMoves.values.map { $0.destination.name })
        let destination = candidates.first(where: {
            !$0.isPinnedGroup && !$0.isArchived &&
                ($0 === source || ($0.usesAutomaticDisplayName && !$0.preservesEmptyView)) &&
                MonitorViewportId($0.workspaceMonitor) == MonitorViewportId(source.workspaceMonitor) && !reserved.contains($0.name) &&
                workspaceOwnedMinimizedWindows($0).isEmpty &&
                $0.allLeafWindowsRecursive.allSatisfy { $0 === window } &&
                (surfaceTree.roots[$0.name] ?? []).flatMap(\.surfaces).allSatisfy { $0 == window?.surfaceID } &&
                !profileMoveDestinations.contains($0.name) &&
                rows(in: $0.name).isEmpty
        }) ?? createBlankWorkspace(projectId: source.projectId, monitor: source.workspaceMonitor)
        positionStandaloneWorkspace(destination, after: source)
        return destination
    }

    func positionStandaloneWorkspace(_ destination: Workspace, after source: Workspace) {
        guard destination !== source, destination.projectId == source.projectId else { return }
        if source.isPinnedGroup {
            // Regular arrivals from a pin belong immediately below the pin shelf.
            if let first = projectWorkspaces(projectId: source.projectId).first(where: {
                $0 !== destination && !$0.isPinnedGroup && !$0.isArchived &&
                    MonitorViewportId($0.workspaceMonitor) == MonitorViewportId(source.workspaceMonitor)
            }) {
                reorderWorkspace(destination.name, relativeTo: first.name, placement: .before)
            }
        } else {
            reorderWorkspace(destination.name, relativeTo: source.name, placement: .after)
        }
    }

    /// Capture and validate both owners before committing a split or stack.
    @discardableResult
    func combineViews(_ source: SurfaceID, with target: SurfaceID, layout: SurfaceContainerLayout,
                      before: Bool = false) -> Bool {
        guard source != target, canCombinePinnedView(containing: source), canCombinePinnedView(containing: target), let sourceName = workspaceName(for: source),
              let sourceWorkspace = Workspace.existing(byName: sourceName),
              let targetName = workspaceName(for: target), let destination = Workspace.existing(byName: targetName),
              sourceWorkspace.projectId == destination.projectId,
              sourceWorkspace.isPinnedGroup == destination.isPinnedGroup,
              isAvailable(source), isAvailable(target) else { return false }
        let changed = editOrganization(of: source, movingTo: destination) { tree in
            layout == .stack ? tree.insertIntoStack(source, with: target)
                : tree.split(source, beside: target, layout: layout, before: before)
        }
        if changed { _ = select(source) }
        return changed
    }

    @discardableResult
    func separateView(_ id: SurfaceID) -> Bool {
        guard let name = workspaceName(for: id), let source = Workspace.existing(byName: name),
              canSeparateView(id) else { return false }
        if source.isPinnedGroup {
            if pinnedViews.contains(where: { $0.workspaceName == name }) {
                let changed = separatePinnedDesktopMember(id)
                if changed { _ = select(id) }
                return changed
            }
            // The pin remains pinned; only its explicit combination is removed.
            let changed = editOrganization(of: id) { $0.moveToRoot(id, in: name) }
            if changed, let pin = pinID(for: id) { detachPinFromSavedGroup(pin) }
            if changed { _ = select(id) }
            return changed
        }
        let target = newStandaloneWorkspace(in: source)
        guard target !== source else { return false }
        let changed = editOrganization(of: id, movingTo: target) { _ in true }
        if changed { _ = select(id) }
        return changed
    }

    func canSeparateView(_ id: SurfaceID) -> Bool {
        guard canMoveSurface(id), let name = workspaceName(for: id),
              let workspace = Workspace.existing(byName: name) else { return false }
        if workspace.isPinnedGroup { return surfaceTree.containingGroup(of: id) != nil }
        return (surfaceTree.roots[name] ?? []).flatMap(\.surfaces).count > 1
    }

    @discardableResult
    func combineGroupViews(_ id: UUID, with target: SurfaceID, layout: SurfaceContainerLayout, before: Bool) -> Bool {
        guard let group = surfaceTree.group(id), !group.surfaces.contains(target),
              group.surfaces.allSatisfy({ canCombinePinnedView(containing: $0) }), canCombinePinnedView(containing: target),
              let name = workspaceName(forGroup: id), let source = Workspace.existing(byName: name),
              let targetName = workspaceName(for: target), let destination = Workspace.existing(byName: targetName),
              source.projectId == destination.projectId, source.isPinnedGroup == destination.isPinnedGroup,
              let first = group.surfaces.first else { return false }
        let edit: (inout SurfaceTree) -> Bool = { $0.combineRootGroup(id, with: target, layout: layout, before: before) }
        let changed = source === destination ? editOrganization(of: first, edit) : moveGroup(id, to: destination, edit: edit)
        if changed { _ = select(first) }
        return changed
    }

    func placeOrdinaryNativeArrival(_ window: Window, in source: Workspace) {
        guard !window.isFloating,
              window.parent is TilingContainer, window.nodeWorkspace === source else { return }
        if config.newItemPlacement != .newView {
            guard hasSharedLayout(in: source) else { return }
            let id = window.surfaceID
            let selected = focusCoordinator.target ?? focus.windowOrNil?.surfaceID
            let anchor = selected.flatMap { surfaceTree.workspace(of: $0) == source.name && $0 != id ? $0 : nil }
            surfaceTree.reconcile((surfaceTree.roots[source.name] ?? []).flatMap(\.surfaces) + [id], in: source.name)
            if config.newItemPlacement == .stackNative, let anchor, let stack = surfaceTree.stack(containing: anchor) {
                _ = surfaceTree.insertIntoStack(.surface(id), with: anchor, inStack: stack)
                if case .group(_, let children) = surfaceTree.group(stack),
                   let index = children.firstIndex(where: { $0.surfaces.contains(anchor) }) {
                    _ = surfaceTree.reorder(.surface(id), inStack: stack, toIndex: index + 1)
                }
            } else { _ = surfaceTree.moveToRoot(id, in: source.name, after: anchor) }
            scheduleRefresh()
            return
        }
        if let pin = nativeAppSidebarPins.first(where: {
            $0.bundleIdentifier == window.app.rawAppBundleId && pendingNativePinLaunches[$0.id] != nil
        }), adoptAppWindow(window, pinID: pin.id) { return }
        let destination = newStandaloneWorkspace(in: regularArrivalWorkspace(source), excluding: window)
        guard destination !== source else { return }
        window.bind(to: destination.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }
}
