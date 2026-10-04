import WorkspaceCore

struct WorkspaceSidebarWindowViewModel: Hashable, Identifiable {
    let windowId: UInt32
    let workspaceName: String
    let appName: String
    let appBundleId: String?
    let appBundlePath: String?
    let title: String?
    let isFocused: Bool
    let surfaceID: SurfaceID

    var id: SurfaceID { surfaceID }
}

struct WorkspaceSidebarTabGroupViewModel: Hashable, Identifiable {
    let representativeWindowId: UInt32
    let workspaceName: String
    let title: String
    let windowCount: Int
    let isFocused: Bool
    let tabs: [WorkspaceSidebarWindowViewModel]
    var searchVisibleTabs: [WorkspaceSidebarWindowViewModel]? = nil

    var id: String { "group:\(representativeWindowId)" }
}
