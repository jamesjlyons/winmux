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
    let items: [WorkspaceSidebarItemViewModel]

    var isPinnedGroup: Bool = false
    var pins: [WorkspaceSidebarPinViewModel] = []
    var totalViewSurfaceCount: Int? = nil

    var viewSurfaces: [WorkspaceSidebarSurfaceItem] { items.flatMap(\.surfaceItems) }
    var viewSurfaceCount: Int { totalViewSurfaceCount ?? viewSurfaces.count }
    var isSingleWindowView: Bool { viewSurfaceCount == 1 }

    var id: String { name }
}

struct WorkspaceSidebarMonitorScopeViewModel: Hashable, Identifiable {
    let id: String
    let displayName: String
    let subtitle: String?
    let systemImageName: String
    let isFocusedMonitor: Bool
}
