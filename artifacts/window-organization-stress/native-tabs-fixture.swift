import AppKit

// Synthetic native tab-group transitions. Accessory policy and off-screen
// frames keep this fixture out of regular-app discovery; it never activates.

@MainActor final class Fixture: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var timer: Timer?
    var step = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        for index in 0..<3 {
            let window = NSWindow(contentRect: .init(x: 5000 + index * 500, y: 0, width: 480, height: 320),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "WinMux native tab fixture \(index)"
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.orderFront(nil)
            windows.append(window)
        }
        report()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
    }
    func advance() {
        step += 1
        switch step {
        case 1:
            windows[0].tabbingMode = .preferred; windows[1].tabbingMode = .preferred
            windows[0].addTabbedWindow(windows[1], ordered: .above)
            windows[0].tabGroup?.selectedWindow = windows[0]
        case 2: windows[0].tabGroup?.selectedWindow = windows[1]
        case 3: windows[0].tabGroup?.selectedWindow = windows[0]
        case 4: windows[0].tabGroup?.removeWindow(windows[1]); windows[1].orderFront(nil)
        case 5: NSApplication.shared.terminate(nil)
        default: break
        }
        report()
    }
    func report() {
        let value: [String: Any] = ["pid": getpid(), "step": step, "windows": windows.map {
            ["id": $0.windowNumber, "visible": $0.isVisible, "selected": $0.tabGroup?.selectedWindow?.windowNumber ?? 0,
             "tabs": $0.tabbedWindows?.map(\.windowNumber) ?? []] as [String: Any]
        }]
        print(String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!)
        fflush(stdout)
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let fixture = Fixture(); app.delegate = fixture
    withExtendedLifetime(fixture) { app.run() }
}
