import WorkspaceCore

enum WorkspaceSidebarSearchSelection: Hashable {
    case workspace(String)
    case surface(SurfaceID)
}

func workspaceSidebarSearchSelections(
    workspaces: [WorkspaceSidebarWorkspaceViewModel],
) -> [WorkspaceSidebarSearchSelection] {
    workspaces.flatMap { workspace in
        let itemSelections = workspace.items.flatMap { item -> [WorkspaceSidebarSearchSelection] in
            switch item.kind {
                case .window(let window):
                    return [.surface(window.surfaceID)]
                case .tabGroup(let group):
                    return (group.searchVisibleTabs ?? group.tabs).map { .surface($0.surfaceID) }
            }
        }
        return itemSelections.isEmpty ? [.workspace(workspace.name)] : itemSelections
    }
}
