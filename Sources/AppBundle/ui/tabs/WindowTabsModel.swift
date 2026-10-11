import AppKit
import Common

@MainActor
func updateWindowTabModel() async {
    let interval = signposter.beginInterval("Tab model", "event: \(refreshSessionEvent?.description ?? "background")")
    defer { signposter.endInterval("Tab model", interval) }
    let didClearMouseInteractionChromeSuppression =
        WindowTabStripPanelController.shared.clearMouseInteractionChromeSuppressionIfInactive()
    guard TrayMenuModel.shared.isEnabled, config.windowTabs.enabled else {
        TrayMenuModel.shared.setIfChanged(\.windowTabStrips, [])
        WindowTabStripPanelController.shared.refresh()
        debugFocusLog("updateWindowTabModel disabled -> cleared")
        return
    }
    let revision = ChromePublicationRevision()
    let strips = await buildWindowTabStripViewModelsFromChromeItems()
    guard !Task.isCancelled, revision == ChromePublicationRevision() else {
        InteractionChromeScheduler.shared.schedule()
        return
    }

    if TrayMenuModel.shared.windowTabStrips != strips {
        debugFocusLog("updateWindowTabModel apply strips old=\(TrayMenuModel.shared.windowTabStrips.map(\.frame)) new=\(strips.map(\.frame))")
        TrayMenuModel.shared.windowTabStrips = strips
        WindowTabStripPanelController.shared.refresh()
    } else {
        if didClearMouseInteractionChromeSuppression {
            WindowTabStripPanelController.shared.refresh()
        }
        debugFocusLog("updateWindowTabModel unchanged strips=\(strips.map(\.frame))")
    }
}
