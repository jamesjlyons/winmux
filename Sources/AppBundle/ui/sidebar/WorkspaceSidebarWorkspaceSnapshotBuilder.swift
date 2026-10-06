@MainActor
func buildWorkspaceSidebarWorkspaceViewModels(
    currentFocus: LiveFocus,
    workspaceLabels: [String: String],
    availableMonitors: [Monitor],
) async -> [WorkspaceSidebarWorkspaceViewModel] {
    let orderedWorkspaces = orderedWorkspacesForPresentation()
    let automaticIndices = automaticWorkspaceDisplayIndices(workspaces: orderedWorkspaces, focusedWorkspace: currentFocus.workspace)
    var nativeItems: [String: [WorkspaceSidebarItemViewModel]] = [:]
    for workspace in orderedWorkspaces {
        nativeItems[workspace.name] = await buildWorkspaceSidebarNativeItems(for: workspace, currentFocus: currentFocus)
    }
    // Finish asynchronous native reads before taking the browser snapshot. No
    // suspension below can let an old inventory resurrect a just-closed tab.
    let pinsByWorkspace = BrowserWorkspaceController.shared.pinTilesByWorkspace()
    let browserProjection = BrowserWorkspaceController.shared.sidebarProjection()
    var workspaces: [WorkspaceSidebarWorkspaceViewModel] = []
    for workspace in orderedWorkspaces {
        workspaces.append(makeWorkspaceSidebarWorkspaceViewModel(
            workspace,
            currentFocus: currentFocus,
            workspaceLabels: workspaceLabels,
            availableMonitors: availableMonitors,
            automaticIndices: automaticIndices,
            pins: pinsByWorkspace[workspace.name] ?? [],
            nativeItems: nativeItems[workspace.name] ?? [],
            browserProjection: browserProjection,
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
    pins: [WorkspaceSidebarPinViewModel],
    nativeItems: [WorkspaceSidebarItemViewModel],
    browserProjection: BrowserSidebarProjection,
) -> WorkspaceSidebarWorkspaceViewModel {
    let interval = signposter.beginInterval("Sidebar workspace model", "workspace: \(workspace.id.rawValue)")
    defer { signposter.endInterval("Sidebar workspace model", interval) }
    let workspaceMonitor = workspace.workspaceMonitor
    let items = BrowserWorkspaceController.shared.organizedRows(native: nativeItems, in: workspace.name, projection: browserProjection)
    let titles = items.flatMap(\.surfaceItems).map(\.title)
    let viewName = workspace.usesAutomaticDisplayName && config.workspaceInteractionMode == .views && !titles.isEmpty
        ? titles.prefix(2).joined(separator: " + ") + (titles.count > 2 ? " + \(titles.count - 2)" : "")
        : workspaceDisplayName(workspace.name, automaticIndices: automaticIndices)
    return WorkspaceSidebarWorkspaceViewModel(
        name: workspace.name,
        projectId: workspace.projectId,
        displayName: viewName,
        sidebarLabel: workspaceLabels[workspace.name] ?? "",
        isGeneratedName: isSidebarDraftWorkspaceName(workspace.name) || workspace.usesAutomaticDisplayName,
        monitorScopeId: workspaceSidebarMonitorScopeId(for: workspaceMonitor),
        monitorName: availableMonitors.count > 1 ? workspaceMonitor.name : nil,
        isFocused: currentFocus.workspace == workspace,
        isVisible: workspace.isVisible,
        items: items,
        isPinnedGroup: workspace.isPinnedGroup,
        pins: pins,
        isViewMode: config.workspaceInteractionMode == .views,
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
