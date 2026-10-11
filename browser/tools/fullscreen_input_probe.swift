// Test-only process-scoped input. No global keystrokes, event taps, page
// scripting or input to any process other than the supplied fixture browser.
import AppKit
import ApplicationServices
import Foundation

guard CommandLine.arguments.count == 2,
      let pid = Int32(CommandLine.arguments[1]), pid > 0 else { exit(2) }
let source = CGEventSource(stateID: .privateState)
func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
}
func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}
func webArea(_ root: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if attribute(root, kAXRoleAttribute as CFString) as? String == "AXWebArea" { return root }
    guard depth < 10,
          let children = attribute(root, kAXChildrenAttribute as CFString) as? [AXUIElement] else { return nil }
    for child in children { if let area = webArea(child, depth: depth + 1) { return area } }
    return nil
}
func playerExit(_ root: AXUIElement, depth: Int = 0) -> AXUIElement? {
    let label = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap {
        attribute(root, $0 as CFString) as? String
    }.joined(separator: " ").lowercased()
    if attribute(root, kAXRoleAttribute as CFString) as? String == "AXButton",
       label.contains("exit full screen") || label.contains("exit fullscreen") { return root }
    guard depth < 15,
          let children = attribute(root, kAXChildrenAttribute as CFString) as? [AXUIElement] else { return nil }
    for child in children { if let button = playerExit(child, depth: depth + 1) { return button } }
    return nil
}
while let command = readLine() {
    guard kill(pid, 0) == 0 else { exit(3) }
    guard CGPreflightPostEventAccess(), AXIsProcessTrusted() else {
        print("input_access_unavailable"); fflush(stdout); continue
    }
    guard let app = NSRunningApplication(processIdentifier: pid) else { exit(3) }
    app.activate()
    let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
    while !app.isActive && DispatchTime.now().uptimeNanoseconds < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    guard app.isActive else { print("fixture_not_active"); fflush(stdout); continue }
    if command == "status" { print("ready"); fflush(stdout); continue }
    if command == "page" {
        let application = AXUIElementCreateApplication(pid)
        let window = element(attribute(application, kAXFocusedWindowAttribute as CFString))
        if let window, let area = webArea(window) {
            let focused = AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            fputs("web_area_focus=\(focused.rawValue)\n", stderr)
            if focused == .success { print("posted"); fflush(stdout); continue }
        }
        print("page_focus_unavailable"); fflush(stdout); continue
    }
    if command == "green" {
        let application = AXUIElementCreateApplication(pid)
        let window = element(attribute(application, kAXFocusedWindowAttribute as CFString))
        let button = window.flatMap {
            element(attribute($0, "AXFullScreenButton" as CFString)) ??
                element(attribute($0, kAXZoomButtonAttribute as CFString))
        }
        let pressed = button.map { AXUIElementPerformAction($0, kAXPressAction as CFString) == .success } ?? false
        print(pressed ? "posted" : "green_button_unavailable"); fflush(stdout); continue
    }
    if command == "player-exit" {
        // Native video controls auto-hide during playback. Reveal them with
        // ordinary keyboard navigation, then allow the AX tree to catch up.
        // Still require the real player exit button and its press action.
        if let down = CGEvent(keyboardEventSource: source, virtualKey: 48, keyDown: true),
           let up = CGEvent(keyboardEventSource: source, virtualKey: 48, keyDown: false) {
            down.postToPid(pid); up.postToPid(pid)
        }
        let controlsDeadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        var pressed = false
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
            let application = AXUIElementCreateApplication(pid)
            let window = element(attribute(application, kAXFocusedWindowAttribute as CFString))
            let button = window.flatMap { webArea($0) }.flatMap { playerExit($0) }
            pressed = button.map { AXUIElementPerformAction($0, kAXPressAction as CFString) == .success } ?? false
        } while !pressed && DispatchTime.now().uptimeNanoseconds < controlsDeadline
        print(pressed ? "posted" : "player_exit_unavailable"); fflush(stdout); continue
    }
    let key: CGKeyCode
    switch command {
    case "input": key = 105 // F13: trusted player entry/exit action.
    case "escape": key = 53
    default: exit(4)
    }
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { exit(5) }
    down.postToPid(pid); up.postToPid(pid)
    print("posted"); fflush(stdout)
}
