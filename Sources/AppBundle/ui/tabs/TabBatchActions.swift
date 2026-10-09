import AppKit
import Common
import WorkspaceCore

@MainActor
func selectedTabSurfaces(_ panes: [SurfacePane], controller: BrowserWorkspaceController = .shared) -> [SurfaceID]? {
    guard !panes.isEmpty, Set(panes).count == panes.count else { return nil }
    var result: [SurfaceID] = []
    for pane in panes {
        switch pane {
        case .surface(let id):
            guard controller.isAvailable(id) else { return nil }
            result.append(id)
        case .group(let id):
            guard let group = controller.surfaceTree.group(id), group.surfaces.allSatisfy(controller.isAvailable) else { return nil }
            result += group.surfaces
        }
    }
    return Set(result).count == result.count ? result : nil
}

@MainActor
func selectedTabsAreMovable(_ ids: [SurfaceID], controller: BrowserWorkspaceController) -> Bool {
    ids.allSatisfy { id in
        if controller.usesSurfaceTree { return controller.canMoveSurface(id) }
        return Window.get(bySurfaceID: id).map { !$0.isFloating && $0.toLiveFocusOrNil() != nil } == true
    }
}

@MainActor
func canGroupSelectedTabs(_ panes: [SurfacePane], controller: BrowserWorkspaceController = .shared) -> Bool {
    guard panes.count > 1, let ids = selectedTabSurfaces(panes, controller: controller),
          selectedTabsAreMovable(ids, controller: controller),
          let first = ids.first, let name = controller.workspaceName(for: first), let source = Workspace.existing(byName: name) else { return false }
    return ids.allSatisfy {
        guard let name = controller.workspaceName(for: $0), let workspace = Workspace.existing(byName: name) else { return false }
        return workspace.projectId == source.projectId && workspace.isPinnedGroup == source.isPinnedGroup && controller.canCombinePinnedView(containing: $0)
    }
}

@MainActor
func canMoveSelectedTabs(_ panes: [SurfacePane], to name: String, controller: BrowserWorkspaceController = .shared) -> Bool {
    guard let destination = Workspace.existing(byName: name), !destination.isArchived, !destination.isPinnedGroup,
          let ids = selectedTabSurfaces(panes, controller: controller), selectedTabsAreMovable(ids, controller: controller) else { return false }
    return ids.contains { controller.workspaceName(for: $0) != name } && ids.allSatisfy { controller.canPlaceSurface($0, in: destination) }
}

@MainActor
func canMoveSelectedTabs(_ panes: [SurfacePane], toProject project: WorkspaceProjectId, controller: BrowserWorkspaceController = .shared) -> Bool {
    guard winMuxWorkspaceState.projectsById[project] != nil,
          let ids = selectedTabSurfaces(panes, controller: controller), selectedTabsAreMovable(ids, controller: controller) else { return false }
    return ids.allSatisfy { id in
        controller.isPrivateSurface(id) ? id.browserProfileID.map { project == .incognito($0) } == true : !project.isIncognito
    }
}

@MainActor
func canSeparateSelectedTabs(_ panes: [SurfacePane], controller: BrowserWorkspaceController = .shared) -> Bool {
    guard let ids = selectedTabSurfaces(panes, controller: controller), selectedTabsAreMovable(ids, controller: controller) else { return false }
    if controller.usesSurfaceTree { return panes.contains { !controller.surfaceTree.ancestors(of: $0).isEmpty } }
    return ids.contains { Window.get(bySurfaceID: $0)?.nearestWindowTabGroup != nil }
}

@MainActor
@discardableResult
func performTabBatchAction(_ panes: [SurfacePane], action: TabBatchAction, controller: BrowserWorkspaceController = .shared) -> Bool {
    guard let ids = selectedTabSurfaces(panes, controller: controller), let first = ids.first else { return false }
    switch action {
    case .close:
        // Resolve all members before closing the first: closing can dissolve a
        // group and must not change the remaining context-menu targets.
        return ids.map { controller.close($0) }.allSatisfy { $0 == .issued }
    case .group(let layout):
        guard canGroupSelectedTabs(panes, controller: controller),
              let name = controller.workspaceName(for: first), let destination = Workspace.existing(byName: name) else { return false }
        if controller.usesSurfaceTree { return controller.arrangeSelectedTabs(panes, in: destination, grouping: layout) }
        let windows = ids.compactMap(Window.get(bySurfaceID:))
        guard let anchor = windows.first else { return false }
        for window in windows { _ = removeWindowFromTabStack(window) }
        let binding = anchor.unbindFromParent()
        let group = TilingContainer(parent: binding.parent, adaptiveWeight: binding.adaptiveWeight,
            layout == .vertical ? .v : .h, layout == .stack ? .tabGroup : .tiles, index: binding.index)
        for window in windows { window.bind(to: group, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST) }
        anchor.markAsMostRecentChild()
        _ = anchor.focusWindow()
        return true
    case .move(let name):
        guard canMoveSelectedTabs(panes, to: name, controller: controller), let destination = Workspace.existing(byName: name) else { return false }
        return moveSelectedTabs(panes, ids: ids, to: destination, controller: controller)
    case .newView(let project, let scope):
        guard canMoveSelectedTabs(panes, toProject: project, controller: controller) else { return false }
        let monitor = workspaceSidebarTargetMonitor(scopeId: scope, fallbackWindow: Window.get(bySurfaceID: first))
        let destination = createBlankWorkspace(projectId: project, monitor: monitor)
        if moveSelectedTabs(panes, ids: ids, to: destination, controller: controller) { return true }
        removeWorkspaceFromRegistry(destination)
        return false
    case .separate:
        guard canSeparateSelectedTabs(panes, controller: controller) else { return false }
        if controller.usesSurfaceTree {
            let names = Set(panes.compactMap { controller.surfaceTree.workspace(of: $0) })
            return controller.editOrganization(in: names) { tree in
                for pane in panes where !tree.ancestors(of: pane).isEmpty {
                    guard tree.separate(pane) else { return false }
                }
                return true
            }
        }
        for id in ids { if let window = Window.get(bySurfaceID: id) { _ = removeWindowFromTabStack(window) } }
        return true
    }
}

@MainActor
private func moveSelectedTabs(_ panes: [SurfacePane], ids: [SurfaceID], to destination: Workspace,
                              controller: BrowserWorkspaceController) -> Bool {
    if controller.usesSurfaceTree { return controller.arrangeSelectedTabs(panes, in: destination) }
    for id in ids {
        guard let window = Window.get(bySurfaceID: id) else { return false }
        applySidebarWorkspaceMove(sourceNode: window, sourceWindow: window, targetWorkspace: destination)
    }
    return true
}
