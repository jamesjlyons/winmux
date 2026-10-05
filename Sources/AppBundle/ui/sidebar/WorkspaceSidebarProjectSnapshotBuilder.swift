@MainActor
func buildWorkspaceSidebarProjectViewModels() -> [WorkspaceSidebarProjectViewModel] {
    workspaceProjects().map {
        WorkspaceSidebarProjectViewModel(
            id: $0.id,
            displayName: $0.name,
            colorHex: config.workspaceSidebar.projectColors[$0.id.rawValue].flatMap(normalizedWorkspaceSidebarColorHex),
            iconName: config.workspaceSidebar.projectIcons[$0.id.rawValue],
            browserProfiles: BrowserWorkspaceController.shared.browserProfiles,
            browserProfileID: BrowserWorkspaceController.shared.browserProfileBySpace[$0.id.rawValue],
            supportsBrowserProfiles: BrowserWorkspaceController.shared.supportsWorkspaceProfiles,
        )
    }
}
