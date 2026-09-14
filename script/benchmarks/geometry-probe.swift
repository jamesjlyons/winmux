import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let previousApp = NSWorkspace.shared.frontmostApplication
let window = NSWindow(contentRect: NSRect(x: 130, y: 170, width: 430, height: 350), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
window.title = "WinMux temporary geometry benchmark"
window.isReleasedWhenClosed = false
var baseline = NSRect.zero
var started: TimeInterval = 0
var settled: Double?
var iteration = 0
func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
func matches(_ a: NSRect, _ b: NSRect) -> Bool {
    abs(a.minX-b.minX) < 1 && abs(a.minY-b.minY) < 1 && abs(a.width-b.width) < 1 && abs(a.height-b.height) < 1
}
let observations = [NSWindow.didResizeNotification, NSWindow.didMoveNotification].map { name in
    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
        if started > 0 && settled == nil && matches(window.frame, baseline) {
            settled = (now()-started)*1000
        }
    }
}
func next() {
    if iteration == 12 {
        window.close()
        previousApp?.activate(options: .activateIgnoringOtherApps)
        DispatchQueue.main.asyncAfter(deadline: .now()+0.5) { app.terminate(nil) }
        return
    }
    baseline = window.frame
    settled = nil
    iteration += 1
    started = now()
    let delta: CGFloat = iteration.isMultiple(of: 2) ? -24 : 24
    window.setFrame(NSRect(x: baseline.minX+delta, y: baseline.minY, width: baseline.width-abs(delta), height: baseline.height), display: true)
    DispatchQueue.main.asyncAfter(deadline: .now()+0.6) {
        print("sample=\(iteration) settleMs=\(settled.map { String(format: "%.3f", $0) } ?? "timeout")")
        fflush(stdout)
        next()
    }
}
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
DispatchQueue.main.asyncAfter(deadline: .now()+2) {
    print("initialFrame=\(window.frame)")
    fflush(stdout)
    next()
}
app.run()
