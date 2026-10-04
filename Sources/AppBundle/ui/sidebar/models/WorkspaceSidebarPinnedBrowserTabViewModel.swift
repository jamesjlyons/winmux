import Foundation
import WorkspaceCore

struct WorkspaceSidebarPinnedBrowserTabViewModel: Hashable, Sendable, Identifiable {
    let pin: BrowserSidebarPin
    let title: String
    let isFocused: Bool
    let isOpen: Bool
    var id: UUID { pin.id }
}
