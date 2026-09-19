import AppKit

// Times observed native key-window changes independently from the CLI acknowledgement.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let previousApp = NSWorkspace.shared.frontmostApplication
let cli = CommandLine.arguments[1]
let label = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "unlabelled"
let windows = (0 ..< 2).map { index in
    let window = NSWindow(contentRect: NSRect(x: 180 + index * 60, y: 180, width: 480, height: 360),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "WinMux temporary focus benchmark \(index + 1)"
    window.isReleasedWhenClosed = false
    return window
}
var iteration = 0
var target: NSWindow?
var started: TimeInterval = 0
var keyMilliseconds: Double?
var commandMilliseconds: Double?
var commandExit: Int32?
var process: Process?
var failures = 0
var finishing = false
func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
func emit(_ fields: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}
func finishSample(timedOut: Bool = false) {
    guard !finishing, timedOut || (keyMilliseconds != nil && commandExit != nil) else { return }
    finishing = true
    if timedOut || commandExit != 0 { failures += 1 }
    if process?.isRunning == true { process?.terminate() }
    emit(["sample": iteration, "label": label, "window": target?.windowNumber ?? -1,
          "nativeFocusMs": keyMilliseconds as Any? ?? NSNull(),
          "commandMs": commandMilliseconds as Any? ?? NSNull(),
          "exitCode": commandExit as Any? ?? NSNull(), "timeout": timedOut])
    target = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { next() }
}
let observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notification in
    guard let window = notification.object as? NSWindow, window === target, keyMilliseconds == nil else { return }
    keyMilliseconds = (now() - started) * 1000
    finishSample()
}
func next() {
    guard iteration < 16 else {
        windows.forEach { $0.close() }
        previousApp?.activate(options: .activateIgnoringOtherApps)
        emit(["label": label, "completed": iteration, "failures": failures])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.removeObserver(observer)
            exit(failures == 0 ? 0 : 1)
        }
        return
    }
    iteration += 1
    let sample = iteration
    target = windows.first { !$0.isKeyWindow }!
    finishing = false
    keyMilliseconds = nil
    commandMilliseconds = nil
    commandExit = nil
    let command = Process()
    command.executableURL = URL(fileURLWithPath: cli)
    command.arguments = ["focus", "--window-id", String(target!.windowNumber)]
    command.standardOutput = FileHandle.nullDevice
    command.standardError = FileHandle.standardError
    command.terminationHandler = { finished in
        let exitedAt = now()
        let status = finished.terminationStatus
        DispatchQueue.main.async {
            guard iteration == sample, !finishing else { return }
            commandMilliseconds = (exitedAt - started) * 1000
            commandExit = status
            finishSample(timedOut: status != 0)
        }
    }
    process = command
    started = now()
    do { try command.run() }
    catch {
        emit(["error": error.localizedDescription])
        finishSample(timedOut: true)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        guard iteration == sample, !finishing else { return }
        finishSample(timedOut: true)
    }
}
windows.forEach { $0.makeKeyAndOrderFront(nil) }
app.activate(ignoringOtherApps: true)
DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
    emit(["label": label, "screen": windows.last?.screen?.localizedName ?? "unknown",
          "screenFrame": String(describing: windows.last?.screen?.frame),
          "windows": windows.map(\.windowNumber)])
    next()
}
app.run()
