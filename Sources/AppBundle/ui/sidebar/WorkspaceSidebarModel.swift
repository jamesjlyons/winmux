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
    let revision = ChromePublicationRevision()
    let state = await buildWorkspaceSidebarModelState()
    guard !Task.isCancelled, revision == ChromePublicationRevision() else {
        InteractionChromeScheduler.shared.schedule()
        return
    }
    applyWorkspaceSidebarModelState(state, previousTopPadding: previousTopPadding)
}
