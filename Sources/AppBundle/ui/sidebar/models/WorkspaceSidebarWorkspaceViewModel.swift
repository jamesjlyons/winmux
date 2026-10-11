struct WorkspaceSidebarWorkspaceViewModel: Hashable, Identifiable {
    let name: String
    let projectId: WorkspaceProjectId
    let displayName: String
    let sidebarLabel: String
    let isGeneratedName: Bool
    let monitorScopeId: String
    let monitorName: String?
    let isFocused: Bool
    let isVisible: Bool
    var items: [WorkspaceSidebarItemViewModel]

    var isPinnedGroup: Bool = false
    var pins: [WorkspaceSidebarPinViewModel] = []
    var totalViewSurfaceCount: Int? = nil

    var viewSurfaces: [WorkspaceSidebarSurfaceItem] { items.flatMap(\.surfaceItems) }
    var viewSurfaceCount: Int { totalViewSurfaceCount ?? viewSurfaces.count }
    var isSingleWindowView: Bool { viewSurfaceCount == 1 }
    var floatingItems: [WorkspaceSidebarItemViewModel] {
        items.filter { item in
            switch item.kind {
            case .window(let window): window.isFloating
            case .surface(let surface): surface.isFloating
            default: false
            }
        }
    }
    // Pin desktops can also own floating dialogs that have no pin tile.
    var showsWindowSection: Bool { !isPinnedGroup || !floatingItems.isEmpty }

    var id: String { name }
}

struct WorkspaceSidebarMonitorScopeViewModel: Hashable, Identifiable {
    let id: String
    let displayName: String
    let subtitle: String?
    let systemImageName: String
    let isFocusedMonitor: Bool
}
