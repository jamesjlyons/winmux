@MainActor
func buildWorkspaceSidebarWorkspaceViewModels(
    currentFocus: LiveFocus,
    workspaceLabels: [String: String],
    availableMonitors: [Monitor],
) async -> [WorkspaceSidebarWorkspaceViewModel] {
    let orderedWorkspaces = orderedWorkspacesForPresentation()
    let automaticIndices = automaticWorkspaceDisplayIndices(workspaces: orderedWorkspaces, focusedWorkspace: currentFocus.workspace)
    var workspaces: [WorkspaceSidebarWorkspaceViewModel] = []
    for workspace in orderedWorkspaces {
        workspaces.append(await makeWorkspaceSidebarWorkspaceViewModel(
            workspace,
            currentFocus: currentFocus,
            workspaceLabels: workspaceLabels,
            availableMonitors: availableMonitors,
            automaticIndices: automaticIndices,
        ))
    }
    return workspaces
}

@MainActor
private func makeWorkspaceSidebarWorkspaceViewModel(
    _ workspace: Workspace,
    currentFocus: LiveFocus,
    workspaceLabels: [String: String],
    availableMonitors: [Monitor],
    automaticIndices: [WorkspaceId: Int],
) async -> WorkspaceSidebarWorkspaceViewModel {
    let interval = signposter.beginInterval("Sidebar workspace model", "workspace: \(workspace.id.rawValue)")
    defer { signposter.endInterval("Sidebar workspace model", interval) }
    let workspaceMonitor = workspace.workspaceMonitor
    return WorkspaceSidebarWorkspaceViewModel(
        name: workspace.name,
        projectId: workspace.projectId,
        displayName: workspaceDisplayName(workspace.name, automaticIndices: automaticIndices),
        sidebarLabel: workspaceLabels[workspace.name] ?? "",
        isGeneratedName: isSidebarDraftWorkspaceName(workspace.name) || workspace.usesAutomaticDisplayName,
        monitorScopeId: workspaceSidebarMonitorScopeId(for: workspaceMonitor),
        monitorName: availableMonitors.count > 1 ? workspaceMonitor.name : nil,
        isFocused: currentFocus.workspace == workspace,
        isVisible: workspace.isVisible,
        items: await buildWorkspaceSidebarItems(for: workspace, currentFocus: currentFocus),
    )
}

func visibleWorkspaceNamesForSidebar(
    workspaces: [WorkspaceSidebarWorkspaceViewModel],
    selectedMonitorScopeId: String,
    focusedMonitorScopeId: String,
) -> Set<String> {
    Set(workspaces.filter {
        workspaceSidebarWorkspaceMatchesScope(
            $0,
            selectedScopeId: selectedMonitorScopeId,
            focusedMonitorScopeId: focusedMonitorScopeId,
        )
    }.map(\.name))
}
