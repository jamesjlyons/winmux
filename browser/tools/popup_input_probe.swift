// Fixed toolbar actions, delivered only to the disposable fixture's PID.
import AppKit
import ApplicationServices
import Foundation

guard CommandLine.arguments.count == 2,
      let pid = Int32(CommandLine.arguments[1]), pid > 0,
      let app = NSRunningApplication(processIdentifier: pid),
      CGPreflightPostEventAccess() else { exit(2) }
let source = CGEventSource(stateID: .privateState)
while let command = readLine() {
    guard kill(pid, 0) == 0 else { exit(3) }
    if command == "snapshot" {
        var focused: CFTypeRef?
        let application = AXUIElementCreateApplication(pid)
        var snapshot: [String: String] = ["trusted": String(AXIsProcessTrusted())]
        let status = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused)
        snapshot["status"] = String(status.rawValue)
        if status == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let element = unsafeBitCast(focused, to: AXUIElement.self)
            for name in [kAXRoleAttribute, kAXValueAttribute] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
                   let string = value as? String { snapshot[name] = string }
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: snapshot)
        print(String(data: data, encoding: .utf8)!)
        fflush(stdout)
        continue
    }
    let key: CGKeyCode
    let flags: CGEventFlags
    switch command {
    case "address": key = 37; flags = .maskCommand // Command-L
    case "query": key = 0; flags = [] // A fixed, synthetic autocomplete query.
    case "query-b": key = 11; flags = [] // Alternate query after dismissing cached results.
    case "close": key = 53; flags = [] // Escape
    default: exit(4)
    }
    if !app.isActive { app.activate() }
    let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
    while !app.isActive && DispatchTime.now().uptimeNanoseconds < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    guard app.isActive,
          let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { exit(5) }
    down.flags = flags
    up.flags = flags
    down.postToPid(pid)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    up.postToPid(pid)
    // Keep this short-lived sender alive until WindowServer delivers its events.
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    print("posted")
    fflush(stdout)
}
