import AppKit
import SwiftUI

private struct SettingsDemoActivityKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsDemoAnimationsEnabled: Bool {
        get { self[SettingsDemoActivityKey.self] }
        set { self[SettingsDemoActivityKey.self] = newValue }
    }
}

/// Hosted settings windows retain their SwiftUI tree after closing. Observe the
/// actual window so their demonstration tasks stop while closed or in the
/// background, without discarding editor drafts or the selected settings page.
struct SettingsDemoActivity: NSViewRepresentable {
    @Binding var isActive: Bool

    func makeNSView(context: Context) -> ActivityView {
        ActivityView { isActive = $0 }
    }

    func updateNSView(_ nsView: ActivityView, context: Context) {}

    final class ActivityView: NSView {
        private let update: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []

        init(update: @escaping (Bool) -> Void) {
            self.update = update
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window {
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                             NSWindow.didChangeOcclusionStateNotification,
                             NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                             NSWindow.willCloseNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                        let closing = notification.name == NSWindow.willCloseNotification
                        MainActor.assumeIsolated {
                            self?.publish(closing: closing)
                        }
                    })
                }
            }
            // Avoid publishing SwiftUI state from inside its AppKit update.
            DispatchQueue.main.async { [weak self] in self?.publish() }
        }

        private func publish(closing: Bool = false) {
            update(!closing && window?.isKeyWindow == true && window?.isVisible == true &&
                   window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true)
        }

        isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
