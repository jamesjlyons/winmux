import AppKit

@MainActor
func clearWorkspaceSidebarModelState() {
    TrayMenuModel.shared.setIfChanged(\.workspaceSidebarWorkspaces, [])
    TrayMenuModel.shared.setIfChanged(\.workspaceSidebarMonitorScopes, [])
    TrayMenuModel.shared.setIfChanged(\.workspaceSidebarProjects, [])
    TrayMenuModel.shared.setIfChanged(\.workspaceSidebarShowsMonitorSelector, false)
    WorkspaceSidebarPanel.refreshAll()
}

@MainActor
func applyWorkspaceSidebarModelState(_ state: WorkspaceSidebarModelState, previousTopPadding: CGFloat) {
    let didMonitorScopeChange =
        TrayMenuModel.shared.workspaceSidebarMonitorScopes != state.monitorScopes ||
        TrayMenuModel.shared.workspaceSidebarFocusedMonitorScopeId != state.focusedMonitorScopeId ||
        TrayMenuModel.shared.workspaceSidebarShowsMonitorSelector != state.showsMonitorSelector
    let didProjectChange =
        TrayMenuModel.shared.workspaceSidebarProjects != state.projects ||
        TrayMenuModel.shared.workspaceSidebarActiveProjectId != state.activeProjectId

    updateWorkspaceSidebarTrayModel(with: state)
    let didWorkspaceChange = TrayMenuModel.shared.workspaceSidebarWorkspaces != state.workspaces
    if didWorkspaceChange {
        TrayMenuModel.shared.workspaceSidebarWorkspaces = state.workspaces
    }
    if didWorkspaceChange ||
        state.topPadding != previousTopPadding ||
        didMonitorScopeChange ||
        didProjectChange ||
        WorkspaceSidebarPanel.visiblePanels.isEmpty
    {
        // refreshAll synchronizes each active panel after all shared fields are ready.
        WorkspaceSidebarPanel.refreshAll()
    } else {
        WorkspaceSidebarPanel.syncVisiblePanelModelsFromShared()
    }
}

@MainActor
private func updateWorkspaceSidebarTrayModel(with state: WorkspaceSidebarModelState) {
    TrayMenuModel.shared.setIfChanged(\.workspaceSidebarTopPadding, state.topPadding)
    TrayMenuModel.shared.setIfChanged(\.workspaceSidebarHoveredWorkspaceName, state.hoveredWorkspaceName)
    TrayMenuModel.shared.setIfChanged(\.workspaceSidebarProjects, state.projects)
    TrayMenuModel.shared.setIfChanged(\.workspaceSidebarActiveProjectId, state.activeProjectId)
    TrayMenuModel.shared.setIfChanged(\.workspaceSidebarMonitorScopes, state.monitorScopes)
    TrayMenuModel.shared.setIfChanged(\.workspaceSidebarFocusedMonitorScopeId, state.focusedMonitorScopeId)
    TrayMenuModel.shared.setIfChanged(\.workspaceSidebarShowsMonitorSelector, state.showsMonitorSelector)
}
