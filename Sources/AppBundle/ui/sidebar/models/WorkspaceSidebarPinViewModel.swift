import Foundation
import WorkspaceCore

struct WorkspaceSidebarPinViewModel: Hashable, Identifiable, Sendable {
    let id: UUID
    let workspaceName: String
    let title: String
    let bundleIdentifier: String?
    let bundlePath: String?
    let iconPNGBase64: String?
    let surfaceID: SurfaceID?
    let isFocused: Bool
    let isOpen: Bool
    let isLoading: Bool
    let isUnavailable: Bool
    let isBrowser: Bool
    var url: String? = nil
    var groupMembers: [WorkspaceSidebarPinViewModel] = []
    var isGroup: Bool { !groupMembers.isEmpty }
}
