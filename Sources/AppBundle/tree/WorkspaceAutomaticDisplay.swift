/// One snapshot of automatic numbering for bulk presentation. Rebuild at the call site so
/// reordering, visibility, project changes and window lifecycle changes cannot stale a cache.
@MainActor
func automaticWorkspaceDisplayIndices(workspaces: [Workspace], focusedWorkspace: Workspace?) -> [WorkspaceId: Int] {
    var counts: [WorkspaceProjectId: Int] = [:]
    var indices: [WorkspaceId: Int] = [:]
    for workspace in workspaces where workspace.usesAutomaticDisplayName &&
        isUserFacingWorkspace(workspace, focusedWorkspace: focusedWorkspace)
    {
        counts[workspace.projectId, default: 0] += 1
        indices[workspace.id] = counts[workspace.projectId]
    }
    return indices
}

@MainActor
func automaticWorkspaceDisplayIndex(_ workspace: Workspace, focusedWorkspace: Workspace?) -> Int? {
    orderedWorkspacesForPresentation()
        .filter { $0.projectId == workspace.projectId }
        .filter { userFacingWorkspaces([$0], focusedWorkspace: focusedWorkspace).contains($0) }
        .filter(\.usesAutomaticDisplayName)
        .firstIndex(of: workspace)
        .map { $0 + 1 }
}

func automaticWorkspaceDisplayIndexFallback(_ workspaceName: String) -> Int? {
    sidebarDraftWorkspaceIndex(workspaceName) ?? automaticWorkspaceIndex(workspaceName)
}

@MainActor
func scopedAutomaticDisplayWorkspaces(current: Workspace) -> [Workspace] {
    orderedWorkspacesForPresentation()
        .filter { $0.projectId == current.projectId }
        .filter { userFacingWorkspaces([$0], focusedWorkspace: current).contains($0) }
        .filter(\.usesAutomaticDisplayName)
}

@MainActor
func createAdjacentTransientBlankWorkspaceIfAllowed(named workspaceName: String, from current: Workspace) -> Workspace? {
    guard let targetIndex = parsePositiveWorkspaceDisplayIndex(workspaceName) else {
        return nil
    }
    let automaticDisplayWorkspaces = scopedAutomaticDisplayWorkspaces(current: current)
    guard targetIndex == automaticDisplayWorkspaces.count + 1 else { return nil }
    if let lastWorkspace = automaticDisplayWorkspaces.last,
       automaticDisplayWorkspaces.count > 1,
       lastWorkspace.isOrdinaryEmptySlot {
        return nil
    }

    let workspace = Workspace.get(byName: nextSidebarCreatedWorkspaceName(projectId: current.projectId, monitor: current.workspaceMonitor))
    workspace.markAsTransientBlank()
    workspace.assignProject(current.projectId)
    return workspace
}
