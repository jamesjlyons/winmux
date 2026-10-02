// A content-free native application for manual Computer Use integration tests.
// It never observes other apps or synthesizes input.
import AppKit

@MainActor final class Fixture: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var windows: [NSWindow] = []
    var keyChanges = 0
    func windowDidBecomeKey(_ notification: Notification) {
        guard CommandLine.arguments.count >= 2, let window = notification.object as? NSWindow else { return }
        keyChanges += 1
        writeReport(window)
    }
    func windowDidMove(_ notification: Notification) { writeReport(NSApplication.shared.keyWindow) }
    func windowDidResize(_ notification: Notification) { writeReport(NSApplication.shared.keyWindow) }
    private func writeReport(_ key: NSWindow?) {
        guard CommandLine.arguments.count >= 2 else { return }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let geometry: [[String: Any]] = windows.map { window in
            ["title": window.title, "window_id": window.windowNumber,
             "x": window.frame.minX, "y": screenHeight - window.frame.maxY,
             "width": window.frame.width, "height": window.frame.height,
             "content_minimum_width": window.contentMinSize.width, "content_minimum_height": window.contentMinSize.height]
        }
        let report: [String: Any] = ["key_window": key?.title ?? "", "key_changes": keyChanges,
                                    "window_id": key?.windowNumber ?? 0, "windows": geometry]
        if let data = try? JSONSerialization.data(withJSONObject: report) {
            try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        for (index, name) in ["One", "Two"].enumerated() {
            let window = NSWindow(contentRect: NSRect(x: 400 + index * 50, y: 300, width: 500, height: 360),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.delegate = self
            // Optional owner constraint for minimum-size negotiation tests.
            if CommandLine.arguments.count == 3, let width = Double(CommandLine.arguments[2]), width > 0 {
                window.contentMinSize = NSSize(width: width, height: 350)
            }
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
