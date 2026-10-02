import AppKit
import HotKey

/// Register Cmd+L only while an enrolled Chromium app is foreground and a native
/// toolbar can accept it. Unregistering on app switch preserves other apps' keys.
@MainActor
final class BrowserToolbarKeyboard {
    private let canFocus: () -> Bool
    private let focus: () -> Void
    private let onActivation: () -> Void
    private var activationObserver: NSObjectProtocol?
    private var shortcut: HotKey?

    init(canFocus: @escaping () -> Bool, focus: @escaping () -> Void, onActivation: @escaping () -> Void = {}) {
        self.canFocus = canFocus
        self.focus = focus
        self.onActivation = onActivation
    }

    func refresh() {
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Raising a Chromium window can separate it from the helper's
                    // adjacent chrome even when logical page selection stays put.
                    // Defer host-relative reordering to the normal layout refresh.
                    self?.onActivation()
                    self?.updateShortcut()
                }
            }
        }
        updateShortcut()
    }

    private func updateShortcut() {
        guard canFocus() else {
            shortcut?.isPaused = true
            shortcut = nil
            return
        }
        guard shortcut == nil else { return }
        shortcut = HotKey(key: .l, modifiers: [.command], keyDownHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.canFocus() else { return }
                self.focus()
            }
        })
    }

    func stop() {
        shortcut?.isPaused = true
        shortcut = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }
}
