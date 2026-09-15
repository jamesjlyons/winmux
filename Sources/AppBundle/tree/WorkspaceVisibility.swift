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
    !workspace.rootTilingContainer.isEffectivelyEmpty ||
        !workspace.floatingWindows.isEmpty
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
    !workspace.isEffectivelyEmpty || !workspaceOwnedMinimizedWindows(workspace).isEmpty
}

@MainActor
func isUserFacingWorkspace(_ workspace: Workspace, focusedWorkspace: Workspace? = nil) -> Bool {
    !workspace.isArchived &&
        (
            workspaceHasSidebarVisibleWindows(workspace) ||
                workspace.isVisible ||
                workspace.isConfiguredPersistent ||
                !workspaceOwnedMinimizedWindows(workspace).isEmpty ||
                workspaceIsRetainedEmptySlot(workspace)
        )
}

@MainActor
func userFacingWorkspaces(_ workspaces: [Workspace], focusedWorkspace: Workspace? = nil) -> [Workspace] {
    let minimizedNames = workspaceNamesWithOwnedMinimizedWindows()
    var retainedIds: [WorkspaceScope: WorkspaceId]?
    return workspaces.filter { workspace in
        guard !workspace.isArchived else { return false }
        if workspaceHasSidebarVisibleWindows(workspace) || workspace.isVisible ||
            workspace.isConfiguredPersistent || minimizedNames.contains(workspace.name)
        { return true }
        // Most occupied groups short-circuit above. Resolve empty slots only when needed,
        // once for this pass, without scanning every minimized window for every group.
        if retainedIds == nil { retainedIds = retainedEmptyWorkspaceIdsByScope(minimizedWorkspaceNames: minimizedNames) }
        return retainedIds?[WorkspaceScope(projectId: workspace.projectId)] == workspace.id
    }
}

@MainActor
func shouldShowWorkspaceInSidebar(_ workspace: Workspace, currentFocus: LiveFocus, isEditingWorkspace: Bool) -> Bool {
    isEditingWorkspace || isUserFacingWorkspace(workspace, focusedWorkspace: currentFocus.workspace)
}
