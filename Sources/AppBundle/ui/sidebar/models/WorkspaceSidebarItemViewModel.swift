import Foundation
import WorkspaceCore

struct WorkspaceSidebarItemViewModel: Hashable, Identifiable, Sendable {
    let kind: WorkspaceSidebarItemKind

    var id: String {
        switch kind {
            case .surface(let item): item.surfaceID.description
            case .surfaceGroup(let id, _): "surface-group:\(id)"
            case .browserTab(let tab):
                tab.surfaceID.description
            case .window(let window):
                window.surfaceID.description
            case .tabGroup(let group):
                group.id
        }
    }
}

indirect enum WorkspaceSidebarItemKind: Hashable, Sendable {
    case surface(WorkspaceSidebarSurfaceItem)
    case surfaceGroup(UUID, [WorkspaceSidebarItemViewModel])
    case browserTab(WorkspaceSidebarBrowserTabViewModel)
    case window(WorkspaceSidebarWindowViewModel)
    case tabGroup(WorkspaceSidebarTabGroupViewModel)
}

struct WorkspaceSidebarSurfaceItem: Hashable, Sendable {
    let surfaceID: SurfaceID
    let title: String
    let appName: String
    let isFocused: Bool
}

extension WorkspaceSidebarItemViewModel {
    var surfaceIDs: [SurfaceID] {
        switch kind {
        case .surface(let item): [item.surfaceID]
        case .surfaceGroup(_, let children): children.flatMap(\.surfaceIDs)
        case .browserTab(let tab): [tab.surfaceID]
        case .window(let window): [window.surfaceID]
        case .tabGroup(let group): group.tabs.map(\.surfaceID)
        }
    }
}
