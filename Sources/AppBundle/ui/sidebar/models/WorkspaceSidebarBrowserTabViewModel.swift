import WorkspaceCore

struct WorkspaceSidebarBrowserTabViewModel: Hashable, Identifiable {
    let surfaceID: SurfaceID
    let workspaceName: String
    let title: String
    let isFocused: Bool
    var id: SurfaceID { surfaceID }
}
