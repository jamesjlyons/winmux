@MainActor
func buildWorkspaceSidebarProjectViewModels() -> [WorkspaceSidebarProjectViewModel] {
    workspaceProjects().map {
        WorkspaceSidebarProjectViewModel(
            id: $0.id,
            displayName: $0.name,
            colorHex: $0.id.isIncognito ? "A78BFA" : config.workspaceSidebar.projectColors[$0.id.rawValue].flatMap(normalizedWorkspaceSidebarColorHex),
            iconName: $0.id.isIncognito ? "eye.slash.fill" : config.workspaceSidebar.projectIcons[$0.id.rawValue],
            browserProfiles: BrowserWorkspaceController.shared.browserProfiles,
            browserProfileID: BrowserWorkspaceController.shared.browserProfileBySpace[$0.id.rawValue],
            supportsBrowserProfiles: !$0.id.isIncognito && BrowserWorkspaceController.shared.supportsWorkspaceProfiles,
        )
    }
}
