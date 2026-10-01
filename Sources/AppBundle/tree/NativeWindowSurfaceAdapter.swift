import WorkspaceCore

/// Resolve again at dispatch time: a stale sidebar item must never focus a new
/// native window that happens to reuse the old numeric window ID.
@MainActor
struct NativeWindowSurfaceAdapter: SurfaceAdapter {
    let surfaceID: SurfaceID
    let capabilities: SurfaceCapabilities = .nativeWindow

    func requestFocus() -> SurfaceActionOutcome {
        guard let window = Window.get(bySurfaceID: surfaceID),
              let target = window.toLiveFocusOrNil() else { return .unavailable }
        guard setFocus(to: target, recordSurfaceIntent: false) else { return .unavailable }
        window.nativeFocus()
        return .issued
    }

    func requestClose() -> SurfaceActionOutcome {
        guard let window = Window.get(bySurfaceID: surfaceID) else { return .unavailable }
        window.closeAxWindow()
        // Keep the item until its owner's close/save flow confirms closure.
        return .issued
    }
}
