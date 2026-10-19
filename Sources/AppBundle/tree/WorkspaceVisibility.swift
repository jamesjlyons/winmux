@MainActor
func orderedUserFacingWorkspaces(in scope: WorkspaceScope, focusedWorkspace: Workspace? = nil) -> [Workspace] {
    userFacingWorkspaces(orderedWorkspaces(in: scope), focusedWorkspace: focusedWorkspace)
}

@MainActor
func orderedUserFacingWorkspaces(in projectId: WorkspaceProjectId, focusedWorkspace: Workspace? = nil) -> [Workspace] {
    userFacingWorkspaces(orderedWorkspaces(in: projectId), focusedWorkspace: focusedWorkspace)
}

@MainActor
func workspaceHasSidebarVisibleWindows(_ workspace: Workspace) -> Bool {
    workspace.existingRootTilingContainer?.isEffectivelyEmpty == false ||
        !workspace.floatingWindows.isEmpty ||
        BrowserWorkspaceController.shared.containsVisibleBrowserItems(in: workspace.name)
}

@MainActor
func workspaceOwnedMinimizedWindows(_ workspace: Workspace) -> [Window] {
    macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self).filter {
        switch $0.layoutReason {
            case .macos(_, let prevWorkspaceName): prevWorkspaceName == workspace.name
            case .standard: false
        }
    }
}

@MainActor
func workspaceNamesWithOwnedMinimizedWindows() -> Set<String> {
    Set(macosMinimizedWindowsContainer.children.compactMap { node in
        guard let window = node as? Window, case .macos(_, let name) = window.layoutReason else { return nil }
        return name
    })
}

@MainActor
func workspaceHasLifecycleWindows(_ workspace: Workspace) -> Bool {
    !workspace.isEffectivelyEmpty || !workspaceOwnedMinimizedWindows(workspace).isEmpty ||
        BrowserWorkspaceController.shared.containsBrowserItems(in: workspace.name)
}

@MainActor
func isUserFacingWorkspace(_ workspace: Workspace, focusedWorkspace: Workspace? = nil) -> Bool {
    if workspaceShouldRemoveEmptyView(workspace) { return false }
    if workspace.isPinnedGroup {
        return BrowserWorkspaceController.shared.hasPins(in: workspace.name) || !workspace.floatingWindows.isEmpty
    }
    return !workspace.isArchived && (workspaceHasSidebarVisibleWindows(workspace) ||
        !workspaceOwnedMinimizedWindows(workspace).isEmpty || workspace.preservesEmptyView ||
        (!workspaceHasLifecycleWindows(workspace) && workspaceIsRetainedEmptySlot(workspace) &&
            showsRetainedEmptySlot(workspace, spaceHasPins: spaceHasPins(workspace.projectId))))
}

/// A Space keeps one ordinary View to land on and to receive new pages. When
/// its only page was pinned, that leftover blank is not a destination the user
/// chose: the pin shelf already represents the Space. Keep it in the model, but
/// show it only while it is on screen.
@MainActor
private func showsRetainedEmptySlot(_ workspace: Workspace, spaceHasPins: Bool) -> Bool {
    !spaceHasPins || workspace.isVisible
}

@MainActor
private func spaceHasPins(_ projectId: WorkspaceProjectId) -> Bool {
    projectWorkspaces(projectId: projectId).contains {
        $0.isPinnedGroup && !$0.isArchived && BrowserWorkspaceController.shared.hasPins(in: $0.name)
    }
}

@MainActor
func userFacingWorkspaces(_ workspaces: [Workspace], focusedWorkspace: Workspace? = nil) -> [Workspace] {
    let minimizedNames = workspaceNamesWithOwnedMinimizedWindows()
    var retainedIds: [WorkspaceScope: WorkspaceId]?
    return workspaces.filter { workspace in
        guard !workspace.isArchived else { return false }
        if workspaceShouldRemoveEmptyView(workspace) { return false }
        if workspace.isPinnedGroup {
            return BrowserWorkspaceController.shared.hasPins(in: workspace.name) || !workspace.floatingWindows.isEmpty
        }
        if workspaceHasSidebarVisibleWindows(workspace) ||
            workspace.preservesEmptyView || minimizedNames.contains(workspace.name)
        { return true }
        if workspaceHasLifecycleWindows(workspace) { return false }
        // Most occupied groups short-circuit above. Resolve empty slots only when needed,
        // once for this pass, without scanning every minimized window for every group.
        if retainedIds == nil { retainedIds = retainedEmptyWorkspaceIdsByScope(minimizedWorkspaceNames: minimizedNames) }
        guard retainedIds?[WorkspaceScope(projectId: workspace.projectId)] == workspace.id else { return false }
        return showsRetainedEmptySlot(workspace, spaceHasPins: spaceHasPins(workspace.projectId))
    }
}

@MainActor
func shouldShowWorkspaceInSidebar(_ workspace: Workspace, currentFocus: LiveFocus, isEditingWorkspace: Bool) -> Bool {
    isEditingWorkspace || isUserFacingWorkspace(workspace, focusedWorkspace: currentFocus.workspace)
}
