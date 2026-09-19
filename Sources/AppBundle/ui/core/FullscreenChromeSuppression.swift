import Foundation

@MainActor
var shouldSuppressChromeForNativeFullscreenContent = false

@MainActor private var fullscreenChromeObservationGeneration: UInt64 = 0

@MainActor
func updateNativeFullscreenChromeSuppression(nativeFocused: Window?) async {
    let interval = signposter.beginInterval("Fullscreen chrome state", id: signposter.makeSignpostID())
    defer { signposter.endInterval("Fullscreen chrome state", interval) }
    fullscreenChromeObservationGeneration += 1
    let generation = fullscreenChromeObservationGeneration
    guard let window = nativeFocused else {
        shouldSuppressChromeForNativeFullscreenContent = false
        return
    }
    if let fullscreen = window.lastKnownNativeFullscreen {
        signposter.emitEvent("Fullscreen state cached")
        shouldSuppressChromeForNativeFullscreenContent = fullscreen
        return
    }
    signposter.emitEvent("Fullscreen state read")
    let token = window.nativeStateObservationToken()
    let fullscreen = try? await window.isMacosFullscreen
    // A newer focus check or geometry/state event makes this observation stale.
    guard generation == fullscreenChromeObservationGeneration,
          token == window.nativeStateObservationToken(),
          Window.get(byId: window.windowId) === window else { return }
    if let fullscreen { window.recordObservedNativeFullscreen(fullscreen, token: token) }
    // A failed lookup keeps the existing visible-chrome fallback, but is never cached.
    shouldSuppressChromeForNativeFullscreenContent = fullscreen == true
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
