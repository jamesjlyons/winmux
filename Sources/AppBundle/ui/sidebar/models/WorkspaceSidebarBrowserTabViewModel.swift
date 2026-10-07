import WorkspaceCore

struct WorkspaceSidebarBrowserTabViewModel: Hashable, Identifiable {
    let surfaceID: SurfaceID
    let workspaceName: String
    let title: String
    let isFocused: Bool
    var iconPNGBase64: String? = nil
    var isSelected = false
    var isLoading = false
    var id: SurfaceID { surfaceID }
}
