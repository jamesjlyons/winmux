// Test-only: read and type into the address field of one supplied isolated
// Chromium PID. Never captures values from any other app or requests access.
import AppKit
import ApplicationServices
import Foundation

guard CommandLine.arguments.count == 2,
      let pid = Int32(CommandLine.arguments[1]), pid > 0 else { exit(2) }
let application = AXUIElementCreateApplication(pid)
let source = CGEventSource(stateID: .privateState)
func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name, &result) == .success ? result : nil
}
func focusedAddress() -> AXUIElement? {
    guard NSRunningApplication(processIdentifier: pid)?.isActive == true,
          let raw = attribute(application, kAXFocusedUIElementAttribute as CFString),
          CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
    let field = unsafeBitCast(raw, to: AXUIElement.self)
    guard attribute(field, kAXRoleAttribute as CFString) as? String == kAXTextFieldRole,
          attribute(field, kAXFocusedAttribute as CFString) as? Bool == true else { return nil }
    return field
}
func typeProbe() -> Bool {
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
    let text = Array("wmprobe".utf16)
    text.withUnsafeBufferPointer {
        down.keyboardSetUnicodeString(stringLength: text.count, unicodeString: $0.baseAddress)
        up.keyboardSetUnicodeString(stringLength: text.count, unicodeString: $0.baseAddress)
    }
    down.postToPid(pid); up.postToPid(pid)
    return true
}
while let command = readLine() {
    guard command == "measure", kill(pid, 0) == 0 else { exit(3) }
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
        print("{\"error\":\"input_or_accessibility_access_unavailable\"}"); fflush(stdout); continue
    }
    var sent = false, acknowledgement: UInt64?
    let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
    repeat {
        if let field = focusedAddress() {
            if !sent { sent = typeProbe() }
            if sent, let value = attribute(field, kAXValueAttribute as CFString) as? String,
               value.contains("wmprobe") {
                acknowledgement = DispatchTime.now().uptimeNanoseconds / 1_000
                break
            }
        }
        Thread.sleep(forTimeInterval: 0.002)
    } while DispatchTime.now().uptimeNanoseconds < deadline
    if let acknowledgement { print("{\"input_ack_us\":\(acknowledgement)}") }
    else { print("{\"error\":\"address_input_not_acknowledged\"}") }
    fflush(stdout)
}
