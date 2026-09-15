import AppKit
import Common

@MainActor
func updateWorkspaceSidebarModel() async {
    let interval = signposter.beginInterval("Sidebar model", "event: \(refreshSessionEvent?.description ?? "background")")
    defer { signposter.endInterval("Sidebar model", interval) }
    guard TrayMenuModel.shared.isEnabled, config.workspaceSidebar.enabled else {
        clearWorkspaceSidebarModelState()
        return
    }

    let previousTopPadding = TrayMenuModel.shared.workspaceSidebarTopPadding
    pruneCachedWindowTitles()
    let state = await buildWorkspaceSidebarModelState()
    applyWorkspaceSidebarModelState(state, previousTopPadding: previousTopPadding)
}
