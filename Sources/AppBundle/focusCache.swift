import Common
import Foundation

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

@MainActor private struct WorkspaceProjectFocusHold {
    let projectId: WorkspaceProjectId
    let expiresAt: Date
}

@MainActor private var workspaceProjectFocusHold: WorkspaceProjectFocusHold? = nil

// AX activation alone is not navigation intent: closing/minimizing often makes
// macOS activate another window of the same app in a hidden Space. Explicit
// WinMux navigation calls setFocus directly; external app switching is recorded
// by the input observer and consumed by the next native focus change.
@MainActor private var nativeSpaceActivationDeadline: Date? = nil

@MainActor
func noteNativeSpaceActivationIntent(_ allowsSpaceChange: Bool) {
    nativeSpaceActivationDeadline = allowsSpaceChange ? Date().addingTimeInterval(2) : nil
}

@MainActor
func shouldAcceptNativeSpaceFocus(in workspace: Workspace) -> Bool {
    workspace.projectId == focus.workspace.projectId || nativeSpaceActivationDeadline.map({ $0 > .now }) == true
}

@MainActor
func resetFocusCacheForTests() {
    lastKnownNativeFocusedWindowId = nil
    workspaceProjectFocusHold = nil
    nativeSpaceActivationDeadline = nil
}

@MainActor
func holdFocusOnWorkspaceProject(_ projectId: WorkspaceProjectId, for duration: TimeInterval) {
    workspaceProjectFocusHold = WorkspaceProjectFocusHold(
        projectId: projectId,
        expiresAt: Date().addingTimeInterval(duration),
    )
}

@MainActor
func clearFocusOnWorkspaceProjectHold(_ projectId: WorkspaceProjectId? = nil) {
    guard projectId == nil || workspaceProjectFocusHold?.projectId == projectId else { return }
    workspaceProjectFocusHold = nil
}

@MainActor
private func activeWorkspaceProjectFocusHold(now: Date = .now) -> WorkspaceProjectFocusHold? {
    guard let hold = workspaceProjectFocusHold else { return nil }
    if hold.expiresAt <= now {
        workspaceProjectFocusHold = nil
        return nil
    }
    return hold
}

@MainActor
private func shouldIgnoreNativeFocusDuringProjectHold(_ nativeFocused: Window?) -> Bool {
    guard let hold = activeWorkspaceProjectFocusHold(),
          let nativeFocused
    else {
        return false
    }
    return nativeFocused.visualWorkspace?.projectId != hold.projectId
}

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if BrowserWorkspaceController.shared.holdsPendingBrowserFocus { return }
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    // A rapid swipe burst can overtake AX focus notifications from an earlier
    // tab. Keep the latest requested tab until native focus catches up.
    if TrackpadNavigationController.shared.shouldIgnoreNativeFocus(nativeFocused) {
        // Reconcile even an unchanged native window after the grace period if
        // activation failed; otherwise the old cache entry could pin selection.
        lastKnownNativeFocusedWindowId = nil
        return
    }
    let lastKnownNativeFocusedWindowIdBefore = lastKnownNativeFocusedWindowId
    if shouldIgnoreNativeFocusDuringProjectHold(nativeFocused) {
        lastKnownNativeFocusedWindowId = nil
        debugFocusLog(
            "updateFocusCache ignoredProjectHold event=\(refreshSessionEvent.prettyDescription) nativeFocused=\(nativeFocused?.windowId.description ?? "nil") lastKnownNative=\(lastKnownNativeFocusedWindowIdBefore?.description ?? "nil") heldProject=\(activeWorkspaceProjectFocusHold()?.projectId.rawValue ?? "nil") logicalFocus=\(debugDescribe(focus))"
        )
        return
    }
    if let workspace = nativeFocused?.visualWorkspace, !shouldAcceptNativeSpaceFocus(in: workspace) {
        // Keep this rejected ID out of the cache so explicit navigation can
        // subsequently accept the very same native window.
        lastKnownNativeFocusedWindowId = nil
        return
    }
    let explicitActivation = nativeSpaceActivationDeadline.map({ $0 > .now }) == true
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId ||
        (explicitActivation && nativeFocused?.visualWorkspace != focus.workspace) {
        if nativeFocused != nil { nativeSpaceActivationDeadline = nil }
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    (nativeFocused?.app as? MacApp)?.lastNativeFocusedWindowId = nativeFocused?.windowId
    debugFocusLog(
        "updateFocusCache event=\(refreshSessionEvent.prettyDescription) nativeFocused=\(nativeFocused?.windowId.description ?? "nil") lastKnownNative=\(lastKnownNativeFocusedWindowIdBefore?.description ?? "nil") -> \(lastKnownNativeFocusedWindowId?.description ?? "nil") logicalFocus=\(debugDescribe(focus))"
    )
}
