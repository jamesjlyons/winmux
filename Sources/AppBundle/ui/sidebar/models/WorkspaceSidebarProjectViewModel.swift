import WorkspaceCore
import Foundation

struct WorkspaceSidebarProjectViewModel: Hashable, Identifiable {
    let id: WorkspaceProjectId
    let displayName: String
    let colorHex: String?
    var iconName: String? = nil
    var browserProfiles: [WorkspaceBrowserProfile] = []
    var browserProfileID: UUID? = nil
    var supportsBrowserProfiles: Bool = false
}
