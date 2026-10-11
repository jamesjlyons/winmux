private struct NativeTabCacheEntry {
    weak var owner: TilingContainer?
    let revision: NativePresentationRevision
    let activeWindowId: UInt32
    let tabs: [WindowTabChromeTabItem]
}
@MainActor private var nativeTabCache: [ObjectIdentifier: NativeTabCacheEntry] = [:]

@MainActor
func pruneNativeTabCache() {
    nativeTabCache = nativeTabCache.filter { $0.value.owner?.isBound == true }
}

@MainActor
func makeWindowTabChromeTabs(
    container: TilingContainer,
    activeWindowId: UInt32,
) -> [WindowTabChromeTabItem] {
    // Session titles return cached values immediately and schedule their own background reads.
    // Keep this snapshot in one main-actor turn instead of creating one task per tab.
    guard let workspace = container.nodeWorkspace else { return [] }
    let revision = NativePresentationRevision(container, workspace: workspace, currentFocus: focus)
    let identity = ObjectIdentifier(container)
    if let cached = nativeTabCache[identity], cached.owner === container,
       cached.revision == revision, cached.activeWindowId == activeWindowId { return cached.tabs }
    let windows = container.children.compactMap(\.tabRepresentativeWindow)
    let tabs = windows.map { makeWindowTabChromeTab(window: $0, activeWindowId: activeWindowId) }
    nativeTabCache[identity] = .init(owner: container, revision: revision, activeWindowId: activeWindowId, tabs: tabs)
    return tabs
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
        isFocused: focus.windowOrNil?.windowId == window.windowId && !BrowserWorkspaceController.shared.hasBrowserSelection,
    )
}
