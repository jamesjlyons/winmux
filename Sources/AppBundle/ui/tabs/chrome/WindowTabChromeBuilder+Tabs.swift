@MainActor
func makeWindowTabChromeTabs(
    container: TilingContainer,
    activeWindowId: UInt32,
) -> [WindowTabChromeTabItem] {
    // Session titles return cached values immediately and schedule their own background reads.
    // Keep this snapshot in one main-actor turn instead of creating one task per tab.
    let windows = container.children.compactMap(\.tabRepresentativeWindow)
    return windows.map { makeWindowTabChromeTab(window: $0, activeWindowId: activeWindowId) }
}

@MainActor
private func makeWindowTabChromeTab(
    window: Window,
    activeWindowId: UInt32,
) -> WindowTabChromeTabItem {
    let appName = window.app.name ?? window.app.rawAppBundleId ?? "Window"
    let title = getSessionWindowTitle(window) ?? appName
    return WindowTabChromeTabItem(
        id: window.windowId,
        title: title,
        appName: appName,
        appBundleIdentifier: window.app.rawAppBundleId,
        isActive: window.windowId == activeWindowId,
    )
}
