import AppKit
import Common

@MainActor
func shouldRaiseNativeFocusedFloatingWindow(
    _ window: Window?,
    previousWindowId: UInt32?,
    event: RefreshSessionEvent,
    foregroundPID: Int32?,
) -> Bool {
    guard !serverArgs.isReadOnly,
          let window, window.isFloating, window.nodeWorkspace?.isVisible == true,
          window.app.pid == foregroundPID,
          window.lastKnownNativeMinimized != true,
          window.lastKnownNativeFullscreen != true
    else { return false }

    switch event {
        case .globalObserver(let notification):
            return notification == NSWorkspace.didActivateApplicationNotification.rawValue
        case .ax(let notification):
            // AXRaise can itself emit a focus notification. Only raise on a
            // transition, so that notification cannot start a raise loop.
            return notification == kAXFocusedWindowChangedNotification as String &&
                previousWindowId != window.windowId
        default:
            return false
    }
}
