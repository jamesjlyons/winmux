import AppKit
import Combine
import SwiftUI

/// The managed helper has no SwiftUI App scene. Host the same Settings view and
/// listen to the existing open request instead of relying on OpenWindowAction.
@MainActor
public func installHostedShortcutSettingsWindow() {
    HostedShortcutSettingsWindow.shared.install()
}

@MainActor
public func requestShortcutSettingsWindow() {
    ShortcutSettingsModel.shared.requestWindowOpen()
}

@MainActor
final class HostedShortcutSettingsWindow: NSObject {
    static let shared = HostedShortcutSettingsWindow()
    private var requests: AnyCancellable?
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    var isInstalled: Bool { requests != nil }

    func install() {
        guard !isInstalled else { return }
        requests = ShortcutSettingsModel.shared.$openRequestId.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.present() }
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "WinMux Workspace")
        item.button?.toolTip = "WinMux Workspace"
        item.menu = settingsMenu()
        statusItem = item
        if NSApp.mainMenu == nil {
            let menu = NSMenu()
            let application = NSMenuItem(title: "WinMux Workspace", action: nil, keyEquivalent: "")
            application.submenu = settingsMenu()
            menu.addItem(application)
            NSApp.mainMenu = menu
        }
    }

    private func settingsMenu() -> NSMenu {
        let menu = NSMenu(title: "WinMux Workspace")
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.target = self
        menu.addItem(settings)
        return menu
    }

    @objc private func openSettings() { requestShortcutSettingsWindow() }

    func windowForPresentation() -> NSWindow {
        if let window { return window }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(shortcutSettingsWindowId)
        window.title = "WinMux Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ShortcutSettingsView(model: .shared).frame(width: 760, height: 620))
        self.window = window
        return window
    }

    func present() {
        ShortcutSettingsModel.shared.reload()
        // Pending browser layout replies must not reclaim focus from this helper
        // window while the user is editing isolated workspace settings.
        if BrowserWorkspaceController.shared.usesSurfaceTree {
            BrowserWorkspaceController.shared.nativeSelectionChanged(nil)
        }
        NSApp.setActivationPolicy(.accessory)
        presentShortcutSettingsWindow(windowForPresentation())
    }
}
