import Foundation
import WorkspaceCore

struct WorkspaceSidebarPinViewModel: Hashable, Identifiable, Sendable {
    var id: UUID
    var workspaceName: String
    var title: String
    var bundleIdentifier: String?
    var bundlePath: String?
    var iconPNGBase64: String?
    var surfaceID: SurfaceID?
    var isFocused: Bool
    var isOpen: Bool
    var isLoading: Bool
    var isUnavailable: Bool
    var isBrowser: Bool
    var sortOrder = 0
    var members: [WorkspaceSidebarPinViewModel] = []
    var isGroup = false
    var memberCount = 1
    var url: String? = nil
}
