// A content-free native application for manual Computer Use integration tests.
// It never observes other apps or synthesizes input.
import AppKit

@MainActor final class Fixture: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var windows: [NSWindow] = []
    var keyChanges = 0
    func windowDidBecomeKey(_ notification: Notification) {
        guard CommandLine.arguments.count == 2, let window = notification.object as? NSWindow else { return }
        keyChanges += 1
        let report: [String: Any] = ["key_window": window.title, "key_changes": keyChanges, "window_id": window.windowNumber]
        if let data = try? JSONSerialization.data(withJSONObject: report) {
            try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        for (index, name) in ["One", "Two"].enumerated() {
            let window = NSWindow(contentRect: NSRect(x: 400 + index * 50, y: 300, width: 500, height: 360),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.delegate = self
            window.title = "WinMux Native \(name)"
            window.isReleasedWhenClosed = false
            let field = NSTextField(frame: NSRect(x: 30, y: 130, width: 420, height: 32))
            field.placeholderString = "Synthetic native input \(name)"
            field.setAccessibilityLabel("Synthetic native input \(name)")
            window.contentView?.addSubview(field)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let fixture = Fixture()
    app.delegate = fixture
    withExtendedLifetime(fixture) { app.run() }
}
