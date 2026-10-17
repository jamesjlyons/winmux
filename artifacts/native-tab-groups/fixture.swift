import AppKit

final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
@MainActor final class Fixture: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var timer: Timer?
    var step = 0
    func makeWindow() -> NSWindow {
        let window = OffscreenWindow(contentRect: .init(x: 8000 + windows.count * 500, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "shell"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.orderFront(nil)
        windows.append(window)
        return window
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        for _ in 0..<5 { _ = makeWindow() }
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        windows[0].tabGroup?.selectedWindow = windows[0]
        windows[3].addTabbedWindow(windows[4], ordered: .above)
        windows[3].tabGroup?.selectedWindow = windows[3]
        report()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
    }
    func advance() {
        step += 1
        switch step {
        case 1:
            windows[0].tabGroup?.selectedWindow = windows[1]
            windows[3].tabGroup?.selectedWindow = windows[4]
        case 2:
            let tab = makeWindow()
            windows[1].addTabbedWindow(tab, ordered: .above)
            windows[1].tabGroup?.selectedWindow = tab
        case 3: windows[5].close()
        case 4: windows[0].tabGroup?.removeWindow(windows[0]); windows[0].orderFront(nil)
        case 5: windows[1].close()
        case 6: windows[4].close()
        case 7: windows[3].close()
        case 8: NSApplication.shared.terminate(nil)
        default: break
        }
        report()
    }
    func report() {
        print(String(data: try! JSONSerialization.data(withJSONObject: ["pid": getpid(), "step": step, "time": ProcessInfo.processInfo.systemUptime,
            "windows": windows.map { ["id": $0.windowNumber, "visible": $0.isVisible,
                "selected": $0.tabGroup?.selectedWindow?.windowNumber ?? $0.windowNumber,
                "tabs": $0.tabbedWindows?.map(\.windowNumber) ?? []] as [String: Any] }], options: [.sortedKeys]), encoding: .utf8)!)
        fflush(stdout)
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let fixture = Fixture(); app.delegate = fixture
    withExtendedLifetime(fixture) { app.run() }
}
