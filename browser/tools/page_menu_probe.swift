import AppKit
import ApplicationServices
import Foundation

// Used only with the disposable signed browser launched by test_browser_page_menu.py.
guard CommandLine.arguments.count == 3,
      let pid = Int32(CommandLine.arguments[1]), pid > 0,
      AXIsProcessTrusted(),
      let running = NSRunningApplication(processIdentifier: pid) else { exit(2) }
let mode = CommandLine.arguments[2]
let app = AXUIElementCreateApplication(pid)
running.activate(options: [])
Thread.sleep(forTimeInterval: 0.5)

func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
}

func find(_ element: AXUIElement, depth: Int = 0,
          matching predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    guard depth < 24 else { return nil }
    if predicate(element) { return element }
    for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = find(child, depth: depth + 1, matching: predicate) { return found }
    }
    return nil
}

func bounds(_ element: AXUIElement) -> CGRect? {
    guard let p = value(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
          let s = value(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
          AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

func click(_ element: AXUIElement) {
    guard let frame = bounds(element), frame.width > 0, frame.height > 0,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { exit(3) }
    let point = CGPoint(x: frame.midX, y: frame.midY)
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    guard let hit = windows.first(where: {
        guard ($0[kCGWindowLayer as String] as? Int) == 0,
              let dict = $0[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return false }
        return rect.contains(point)
    }), (hit[kCGWindowOwnerPID as String] as? Int32) == pid else { exit(4) }
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                mouseButton: .left)!.post(tap: .cghidEventTap)
    }
}

func waitFor(_ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if running.isTerminated { return false }
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return false
}

func item(_ title: String) -> AXUIElement? {
    find(app) {
        value($0, kAXRoleAttribute) as? String == "AXMenuItem" &&
        (value($0, kAXTitleAttribute) as? String ?? "").hasPrefix(title)
    }
}

func openMenu() {
    // AppKit can remove AX menu elements before its dismissal animation ends.
    Thread.sleep(forTimeInterval: 0.5)
    guard let windowValue = value(app, kAXFocusedWindowAttribute),
          CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { exit(5) }
    let window = windowValue as! AXUIElement
    guard let toolbar = find(window, matching: { value($0, kAXRoleAttribute) as? String == "AXToolbar" }),
          let button = find(toolbar, matching: {
              value($0, kAXRoleAttribute) as? String == "AXPopUpButton" &&
              ["Chromium", "WinMux Browser Alpha"].contains(value($0, kAXDescriptionAttribute) as? String ?? "")
          }) else { exit(6) }
    click(button)
    Thread.sleep(forTimeInterval: 0.2)
    guard waitFor({ item(mode == "released" ? "New " : "Keep Active") != nil }) else {
        print("Menu failed to open in \(mode) mode; browser terminated: \(running.isTerminated)")
        exit(7)
    }
}

func escape() {
    for down in [true, false] {
        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)!.postToPid(pid)
    }
    Thread.sleep(forTimeInterval: 0.2)
}

openMenu()
if mode == "released" {
    guard item("Keep Active") == nil else { exit(8) }
    escape()
    print("Released browser menu opens without managed page commands")
    exit(0)
}
guard let keepActive = item("Keep Active"),
      let blocking = item("Block Ads and Trackers on This Site"),
      let privacy = item("Privacy Settings") else { exit(9) }
for element in [keepActive, blocking, privacy] {
    guard value(element, kAXEnabledAttribute) as? Bool == true else { exit(10) }
}
func checked(_ element: AXUIElement) -> Bool {
    !(value(element, "AXMenuItemMarkChar") as? String ?? "").isEmpty
}
// Exercise both check commands, verify their state after reopening, then restore.
for title in ["Keep Active", "Block Ads and Trackers on This Site"] {
    guard let before = item(title) else { exit(11) }
    let original = checked(before)
    guard AXUIElementPerformAction(before, kAXPressAction as CFString) == .success else { exit(12) }
    guard waitFor({ item(title) == nil }) else {
        print("Menu did not close after selecting \(title)")
        exit(12)
    }
    openMenu()
    guard let toggled = item(title), checked(toggled) != original else {
        print("\(title) did not toggle from \(original); mark: \(String(describing: item(title).flatMap { value($0, "AXMenuItemMarkChar") }))")
        exit(13)
    }
    guard AXUIElementPerformAction(toggled, kAXPressAction as CFString) == .success else { exit(14) }
    guard waitFor({ item(title) == nil }) else { exit(14) }
    openMenu()
    guard let restored = item(title), checked(restored) == original else { exit(15) }
}
guard let settings = item("Privacy Settings"),
      AXUIElementPerformAction(settings, kAXPressAction as CFString) == .success,
      waitFor({ find(app, matching: { value($0, kAXRoleAttribute) as? String == "AXSheet" }) != nil }),
      let sheet = find(app, matching: { value($0, kAXRoleAttribute) as? String == "AXSheet" }),
      let cancel = find(sheet, matching: {
          value($0, kAXRoleAttribute) as? String == "AXButton" &&
          value($0, kAXTitleAttribute) as? String == "Cancel"
      }), AXUIElementPerformAction(cancel, kAXPressAction as CFString) == .success,
      waitFor({ find(app, matching: { value($0, kAXRoleAttribute) as? String == "AXSheet" }) == nil }) else { exit(16) }
print("Managed page menu opens; both toggles restore; Privacy Settings opens and cancels")
