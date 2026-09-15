import Foundation

@MainActor
var shouldSuppressChromeForNativeFullscreenContent = false

@MainActor
func updateNativeFullscreenChromeSuppression(nativeFocused: Window?) async {
    shouldSuppressChromeForNativeFullscreenContent = (try? await nativeFocused?.isMacosFullscreen) == true
}

@MainActor
func shouldSuppressChromeForFullscreenContent(on monitor: Monitor) -> Bool {
    shouldSuppressChromeForNativeFullscreenContent
}

@MainActor
func shouldSuppressWorkspaceSidebarForFullscreenContent(on monitor: Monitor) -> Bool {
    if shouldSuppressChromeForNativeFullscreenContent { return true }
    guard let workspace = winMuxWorkspaceState.visibleWorkspace(for: monitor) else { return false }
    let root = workspace.rootTilingContainer
    // Match layoutWorkspace: a fullscreen tab keeps its whole group fullscreen,
    // while a standalone fullscreen window must be the most recent tiled window.
    return root.mostRecentWindowRecursive?.isFullscreen == true ||
        root.allTabbedContainersRecursive.contains(where: \.hasFullscreenTab)
}
