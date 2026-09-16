import SwiftUI

struct TrackpadSettingsSection: View {
    @ObservedObject var model: ShortcutSettingsModel
    @ObservedObject private var controller = TrackpadNavigationController.shared
    @State private var enabled = config.trackpadNavigation.enabled
    @State private var reversed = config.trackpadNavigation.reverseDirection

    var body: some View {
        SettingsSection("Trackpad") {
            SettingsToggle("Three-finger swipe to switch tabs", isOn: $enabled,
                help: "Switch tabs in the focused group. One tab per swipe, wrapping at either end.") {
                    persist("enabled", enabled)
                }
            SettingsToggle("Reverse swipe direction", isOn: $reversed,
                help: "By default, swipe left for the next tab and right for the previous tab.") {
                    persist("reverse-direction", reversed)
                }
                .disabled(!enabled)
            VStack(alignment: .leading, spacing: 8) {
                Text(controller.status.description)
                Text("Set macOS desktop switching to four fingers, page navigation to two fingers, and turn off three-finger dragging to avoid conflicts.")
                HStack {
                    Button("Trackpad Settings…") { openSettings("com.apple.Trackpad-Settings.extension") }
                    Button("Pointer Control…") { openSettings("com.apple.preference.universalaccess?Mouse") }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
        }
    }

    private func persist(_ key: String, _ value: Bool) {
        persistSettingsConfig(section: "trackpad-navigation", key: key, renderedValue: value ? "true" : "false", model: model)
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }
}
