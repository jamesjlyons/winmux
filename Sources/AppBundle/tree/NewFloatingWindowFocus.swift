@MainActor private var pendingNewFloatingWindows: [Window] = []

@MainActor
func noteNewFloatingWindow(_ window: Window) {
    guard !isStartup, !serverArgs.isReadOnly, window.isFloating else { return }
    pendingNewFloatingWindows.append(window)
}

@MainActor
func clearNewFloatingWindowFocusRequests() {
    pendingNewFloatingWindows.removeAll()
}

/// Run after native-state normalization and placement, so minimized windows and
/// windows routed to another workspace stay there. Consume each opening once;
/// subsequent refreshes must not keep raising a window the user put behind.
@MainActor
@discardableResult
func focusNewFloatingWindowAfterLayout() -> Bool {
    let candidates = pendingNewFloatingWindows
    clearNewFloatingWindowFocusRequests()
    guard !isStartup, !serverArgs.isReadOnly else { return false }
    for window in candidates.reversed() {
        guard let workspace = window.parent as? Workspace,
              workspace.isVisible,
              window.lastKnownNativeMinimized != true,
              window.lastKnownNativeFullscreen != true,
              window.focusWindow()
        else { continue }
        // Request native focus even if AX already names this window: being the
        // app's focused window does not guarantee it is above other apps.
        window.nativeFocus()
        return true
    }
    return false
}
