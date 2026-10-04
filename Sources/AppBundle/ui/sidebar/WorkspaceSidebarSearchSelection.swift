import Foundation
import WorkspaceCore

enum WorkspaceSidebarSearchSelection: Hashable {
    case workspace(String)
    case surface(SurfaceID)
    case pinnedBrowserTab(UUID)
}

func workspaceSidebarSearchSelections(
    workspaces: [WorkspaceSidebarWorkspaceViewModel],
) -> [WorkspaceSidebarSearchSelection] {
    workspaces.flatMap { workspace -> [WorkspaceSidebarSearchSelection] in
        if workspace.isPinnedGroup { return workspace.pins.map { .pinnedBrowserTab($0.id) } }
        let itemSelections = workspace.items.flatMap { item -> [WorkspaceSidebarSearchSelection] in
            switch item.kind {
                case .pinnedBrowserTab(let tab):
                    return [.pinnedBrowserTab(tab.id)]
                case .surface, .surfaceGroup:
                    return item.surfaceIDs.map { .surface($0) }
                case .browserTab(let tab):
                    return [.surface(tab.surfaceID)]
                case .window(let window):
                    return [.surface(window.surfaceID)]
                case .tabGroup(let group):
                    return (group.searchVisibleTabs ?? group.tabs).map { .surface($0.surfaceID) }
            }
        }
        return itemSelections.isEmpty ? [.workspace(workspace.name)] : itemSelections
    }
}
