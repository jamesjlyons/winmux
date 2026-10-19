// Native input and screenshot qualification for a synthetic compact-toolbar page.
import AppKit
import ApplicationServices
import Foundation
import Vision

if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--frontmost-pid" {
    print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
    exit(0)
}
guard [4, 5].contains(CommandLine.arguments.count),
      let pid = Int32(CommandLine.arguments[1]), pid > 0, AXIsProcessTrusted() else { exit(2) }
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let originalURL = CommandLine.arguments[3]
// Chromium's full editing form omits only the ordinary http:// prefix. Copy
// must still return the complete URL, including that scheme, path and fragment.
func matchesEditingURL(_ text: String?) -> Bool {
    text == originalURL || (originalURL.hasPrefix("http://") && text == String(originalURL.dropFirst(7)))
}
guard let expected = URL(string: originalURL), let expectedHost = expected.host,
      expectedHost.hasSuffix("toolbar.test") || expectedHost.hasSuffix(".localhost"),
      let application = NSRunningApplication(processIdentifier: pid) else { exit(3) }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let app = AXUIElementCreateApplication(pid)
var results: [String: Any] = ["passed": false, "pid": pid]
func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
}
func descendants(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 16 else { return [] }
    return [element] + (value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap { descendants($0, depth: depth + 1) }
}
func bounds(_ element: AXUIElement) -> CGRect? {
    guard let p = value(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
          let s = value(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}
struct Failure: Error { let message: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(message: message) }
}
func wait(_ message: String, _ condition: () -> Bool) throws {
    let end = Date().addingTimeInterval(8)
    while Date() < end {
        if condition() { return }
        Thread.sleep(forTimeInterval: 0.05)
    }
    throw Failure(message: message)
}
func fixtureControl(_ action: String, peer: Bool = false) throws {
    let directory = output.deletingLastPathComponent()
    let commandFile = directory.appendingPathComponent("fullscreen-command.json")
    let current = try JSONSerialization.jsonObject(with: Data(contentsOf: commandFile)) as! [String: Any]
    let sequence = (current["sequence"] as! Int) + 1
    let data = try JSONSerialization.data(withJSONObject: ["sequence": sequence, "action": action, "peer": peer])
    try data.write(to: commandFile, options: .atomic)
    try wait("Fixture control did not complete: \(action)") {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("helper.json")),
              let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outcomes = report["outcomes"] as? [String: Any] else { return false }
        return outcomes["video_command"] as? String == "\(sequence):issued"
    }
}
func windows() -> [[String: Any]] {
    (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
}
func move(_ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.25)
}
func click(_ point: CGPoint) throws {
    try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, "Fixture is not frontmost")
    let top = windows().first {
        guard let dictionary = $0[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return false }
        return rect.contains(point)
    }
    try require((top?[kCGWindowOwnerPID as String] as? Int32) == pid, "Click target is not the fixture")
    move(point)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.25)
}
func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = flags; event.postToPid(pid)
    }
    Thread.sleep(forTimeInterval: 0.15)
}
func type(_ text: String) {
    var units = Array(text.utf16)
    let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
    event.postToPid(pid)
    Thread.sleep(forTimeInterval: 0.2)
}
func capture(_ name: String, frame: CGRect) throws -> [String] {
    guard let cg = windows().first(where: {
        guard ($0[kCGWindowOwnerPID as String] as? Int32) == pid,
              let dict = $0[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return false }
        return abs(rect.minX - frame.minX) < 2 && abs(rect.minY - frame.minY) < 2
    }), let number = cg[kCGWindowNumber as String] as? UInt32 else { throw Failure(message: "Missing fixture window") }
    let file = output.appendingPathComponent(name + ".png")
    let shot = Process(); shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    shot.arguments = ["-x", "-o", "-l", String(number), file.path]
    try shot.run(); shot.waitUntilExit()
    try require(shot.terminationStatus == 0, "Screenshot failed")
    guard let rep = NSBitmapImageRep(data: try Data(contentsOf: file)), let image = rep.cgImage,
          let bar = image.cropping(to: CGRect(x: 0, y: 0, width: image.width,
               height: Int(34 * CGFloat(image.width) / frame.width))) else { throw Failure(message: "Missing toolbar pixels") }
    try NSBitmapImageRep(cgImage: bar).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + "-bar.png"))
    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: bar).perform([request])
    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    results[name + "_text"] = text
    return text
}
let clipboard = NSPasteboard.general
let savedClipboard = (clipboard.pasteboardItems ?? []).map { item in
    item.types.compactMap { kind in item.data(forType: kind).map { (kind, $0) } }
}
var changedClipboard = false
let previousApp = CommandLine.arguments.count == 5
    ? Int32(CommandLine.arguments[4]).flatMap { NSRunningApplication(processIdentifier: $0) }
    : NSWorkspace.shared.frontmostApplication
var inspectedWindow: AXUIElement?
var inspectedField: AXUIElement?

do {
    application.activate(options: [])
    try wait("Fixture did not activate") { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
    guard let window = value(app, kAXFocusedWindowAttribute) as! AXUIElement?,
          let frame = bounds(window), let field = descendants(window).first(where: {
              value($0, kAXDescriptionAttribute) as? String == "Address and search bar"
          }), let fieldFrame = bounds(field) else { throw Failure(message: "Missing native address control") }
    inspectedWindow = window
    inspectedField = field
    let controls = descendants(window)
    guard let toolbar = controls.first(where: { value($0, kAXRoleAttribute) as? String == "AXToolbar" }),
          let toolbarFrame = bounds(toolbar) else { throw Failure(message: "Missing toolbar") }
    try require(abs(toolbarFrame.height - 34) < 1, "Compact toolbar height changed")
    for label in ["Back", "Forward", "Reload"] {
        guard let button = controls.first(where: { value($0, kAXDescriptionAttribute) as? String == label }),
              let rect = bounds(button) else { throw Failure(message: "Missing \(label)") }
        try require(rect.width == 26 && rect.height == 26, "\(label) target size changed")
        try require(abs(rect.midY - toolbarFrame.midY) <= 1, "\(label) is not centered")
    }
    for role in [kAXCloseButtonSubrole, kAXMinimizeButtonSubrole, kAXFullScreenButtonSubrole] {
        guard let button = controls.first(where: { value($0, kAXSubroleAttribute) as? String == role }),
              let rect = bounds(button) else { throw Failure(message: "Missing window control \(role)") }
        try require(abs(rect.midY - toolbarFrame.midY) <= 1, "Window control is not centered")
    }
    results["compact_geometry_passed"] = true
    let body = CGPoint(x: frame.midX, y: frame.minY + 180)
    try click(body)
    try wait("Initial page is not loaded") { (value(field, kAXValueAttribute) as? String ?? "").contains("/a/deep/path") }
    let idle = try capture("idle", frame: frame).joined(separator: " ")
    try require(idle.contains(expectedHost), "Idle hostname was not painted: \(idle)")
    try require(!idle.contains("/a/deep/path") && !idle.contains("query="), "Idle URL path was not hidden")
    try require((value(field, kAXValueAttribute) as? String ?? "").contains("/a/deep/path"), "AX lost the full address")
    guard let siteInfo = descendants(window).first(where: {
        guard value($0, kAXRoleAttribute) as? String == "AXPopUpButton",
              let rect = bounds($0) else { return false }
        return rect.maxX <= fieldFrame.minX && abs(rect.midY - fieldFrame.midY) < 2
    }), let siteInfoFrame = bounds(siteInfo) else {
        throw Failure(message: "Missing site information control")
    }
    move(CGPoint(x: siteInfoFrame.midX, y: siteInfoFrame.midY))
    _ = try capture("site-info-hover", frame: frame)
    try require(AXUIElementPerformAction(siteInfo, kAXPressAction as CFString) == .success,
                "Site information button could not be pressed")
    try wait("Site information did not open") {
        descendants(app).contains {
            (value($0, kAXTitleAttribute) as? String ??
             value($0, kAXDescriptionAttribute) as? String ?? "").contains("Site settings")
        }
    }
    _ = try capture("site-info-open", frame: frame)
    key(53)
    move(body)
    _ = try capture("site-info-restored", frame: frame)
    results["site_info_passed"] = true
    move(CGPoint(x: fieldFrame.midX, y: fieldFrame.midY))
    _ = try capture("hover", frame: frame)
    try click(CGPoint(x: fieldFrame.midX, y: fieldFrame.midY))
    try wait("Mouse did not reveal full URL") { matchesEditingURL(value(field, kAXValueAttribute) as? String) }
    results["focused_address"] = value(field, kAXValueAttribute) as? String
    try require(matchesEditingURL(value(field, kAXSelectedTextAttribute) as? String), "Mouse did not select full URL")
    _ = try capture("focused", frame: frame)
    changedClipboard = true
    key(8, flags: .maskCommand)
    try require(clipboard.string(forType: .string) == originalURL, "Copy lost URL components")
    type("unfinished toolbar draft")
    _ = try capture("editing", frame: frame)
    try require((value(field, kAXValueAttribute) as? String ?? "").contains("unfinished toolbar draft"), "Draft not entered")
    key(53); key(53)
    try click(body)
    let restored = try capture("restored", frame: frame).joined(separator: " ")
    try require(restored.contains(expectedHost) && !restored.contains("unfinished"), "Escape did not restore hostname")
    key(37, flags: .maskCommand)
    try wait("Cmd+L did not select full URL") { matchesEditingURL(value(field, kAXSelectedTextAttribute) as? String) }
    key(53); key(53); try click(body)
    // Navigation update, including another subdomain and path.
    let nextHost = expectedHost.replacingOccurrences(of: "docs.", with: "next.")
    let nextURL = originalURL.replacingOccurrences(of: expectedHost, with: nextHost)
        .replacingOccurrences(of: "/a/deep/path", with: "/second/path")
    key(37, flags: .maskCommand); type(nextURL); key(36)
    try wait("Second URL did not load") { (value(field, kAXValueAttribute) as? String ?? "").contains(nextHost) }
    try click(body)
    let nextText = try capture("navigated", frame: frame).joined(separator: " ")
    try require(nextText.contains(nextHost) && !nextText.contains("/second/path"), "Hostname did not update")
    let back = descendants(window).first { value($0, kAXDescriptionAttribute) as? String == "Back" }
    try require(back != nil, "Missing Back button")
    try require(AXUIElementPerformAction(back!, kAXPressAction as CFString) == .success, "Back failed")
    try wait("Back did not navigate") { (value(field, kAXValueAttribute) as? String ?? "").contains(expectedHost) }
    results["navigation_copy_editing_passed"] = true
    let forward = descendants(window).first { value($0, kAXDescriptionAttribute) as? String == "Forward" }
    try require(forward != nil && AXUIElementPerformAction(forward!, kAXPressAction as CFString) == .success, "Forward failed")
    try wait("Forward did not navigate") { (value(field, kAXValueAttribute) as? String ?? "").contains(nextHost) }
    if let reload = descendants(window).first(where: { value($0, kAXDescriptionAttribute) as? String == "Reload" }) {
        try require(AXUIElementPerformAction(reload, kAXPressAction as CFString) == .success, "Reload failed")
    } else { throw Failure(message: "Missing Reload control") }
    Thread.sleep(forTimeInterval: 0.5)
    // Keep platform-owned site controls and extension/menu hit targets usable.
    results["toolbar_controls"] = descendants(window).compactMap { element -> String? in
        guard let rect = bounds(element), rect.minY < frame.minY + 34,
              value(element, kAXRoleAttribute) as? String == "AXButton" else { return nil }
        return value(element, kAXDescriptionAttribute) as? String
    }
    if let extensions = descendants(window).first(where: { value($0, kAXDescriptionAttribute) as? String == "Extensions" }) {
        try require(AXUIElementPerformAction(extensions, kAXPressAction as CFString) == .success, "Extensions menu failed")
        try wait("Fixture extension is absent from menu") {
            descendants(app).contains { (value($0, kAXTitleAttribute) as? String ?? value($0, kAXDescriptionAttribute) as? String ?? "").contains("Toolbar fixture") }
        }
        key(53)
        results["extensions_menu_passed"] = true
    } else { throw Failure(message: "Missing Extensions control") }
    key(37, flags: .maskCommand)
    type("http://\(expectedHost):\(expected.port!)/download"); key(36)
    let downloaded = output.deletingLastPathComponent().appendingPathComponent("downloads/toolbar-fixture.txt")
    try wait("Download did not complete in isolated directory") { FileManager.default.fileExists(atPath: downloaded.path) }
    key(53)
    _ = try capture("after-download", frame: frame)
    results["download_controls"] = descendants(window).compactMap { element -> [String: String]? in
        guard let rect = bounds(element), rect.minY < frame.minY + 34 else { return nil }
        return ["role": value(element, kAXRoleAttribute) as? String ?? "",
                "title": value(element, kAXTitleAttribute) as? String ?? "",
                "description": value(element, kAXDescriptionAttribute) as? String ?? ""]
    }
    func downloadsControl() -> AXUIElement? {
        descendants(window).first { element in
            guard let rect = bounds(element), rect.minY < frame.minY + 34 else { return false }
            return [kAXTitleAttribute, kAXDescriptionAttribute].contains { attribute in
                (value(element, attribute) as? String ?? "").lowercased().contains("download")
            }
        }
    }
    if let downloads = downloadsControl() {
        try require(AXUIElementPerformAction(downloads, kAXPressAction as CFString) == .success, "Downloads menu failed")
        try wait("Downloaded file missing from native bubble") {
            descendants(app).contains { (value($0, kAXTitleAttribute) as? String ?? value($0, kAXDescriptionAttribute) as? String ?? value($0, kAXValueAttribute) as? String ?? "").contains("toolbar-fixture.txt") }
        }
        key(53)
        results["downloads_bubble_passed"] = true
    } else {
        // Chromium may leave this unpinned action hidden. Its menu route must
        // remain available even when there is no temporary toolbar button.
        guard let menu = descendants(window).first(where: {
            value($0, kAXDescriptionAttribute) as? String == "Chromium"
        }) else { throw Failure(message: "Missing browser menu") }
        try require(AXUIElementPerformAction(menu, kAXPressAction as CFString) == .success, "Browser menu failed")
        try wait("Downloads unavailable in browser menu") {
            descendants(app).contains { (value($0, kAXTitleAttribute) as? String ?? "").contains("Downloads") }
        }
        key(53)
        results["downloads_menu_passed"] = true
    }
    results["downloads_passed"] = true
    // Non-web addresses retain their native display.
    key(37, flags: .maskCommand); type("chrome://version"); key(36)
    try wait("Internal page did not load") { (value(field, kAXValueAttribute) as? String ?? "").contains("chrome://version") }
    try wait("Internal page did not finish navigation") {
        (value(window, kAXTitleAttribute) as? String ?? "").contains("Version") &&
            descendants(window).contains { value($0, kAXDescriptionAttribute) as? String == "Reload" }
    }
    try click(body)
    let internalText = try capture("internal-page", frame: frame).joined(separator: " ")
    try require(internalText.contains("chrome://version"), "Internal URL was abbreviated")
    key(37, flags: .maskCommand); type(originalURL); key(36)
    try wait("Fixture URL did not restore") { (value(field, kAXValueAttribute) as? String ?? "").contains(expectedHost) }
    try click(body)
    // A normal window resize exercises narrow and wide toolbar layouts.
    for width in [480.0, 1000.0] {
        var size = CGSize(width: width, height: frame.height)
        let sizeValue = AXValueCreate(.cgSize, &size)!
        try require(AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success, "Resize failed")
        Thread.sleep(forTimeInterval: 0.4)
        guard let resized = bounds(window) else { throw Failure(message: "No resized bounds") }
        results["width-\(Int(width))_actual_width"] = resized.width
        move(CGPoint(x: resized.midX, y: resized.minY + 180))
        _ = try capture("width-\(Int(width))", frame: resized)
    }
    guard let dragFrame = bounds(window),
          let back = descendants(window).first(where: { value($0, kAXDescriptionAttribute) as? String == "Back" }),
          let backFrame = bounds(back) else { throw Failure(message: "Missing drag geometry") }
    let lightRight = descendants(window).filter {
        [kAXCloseButtonSubrole, kAXMinimizeButtonSubrole, kAXFullScreenButtonSubrole]
            .contains(value($0, kAXSubroleAttribute) as? String ?? "")
    }.compactMap { bounds($0)?.maxX }.max()!
    try require(backFrame.minX - lightRight >= 6, "No native frame gap for drag")
    let start = CGPoint(x: (lightRight + backFrame.minX) / 2, y: dragFrame.minY + 17)
    try click(start) // Verifies the foreground process and window at this point.
    for (kind, point) in [(CGEventType.leftMouseDown, start),
                           (.leftMouseDragged, CGPoint(x: start.x + 12, y: start.y + 10)),
                           (.leftMouseDragged, CGPoint(x: start.x + 24, y: start.y + 20)),
                           (.leftMouseUp, CGPoint(x: start.x + 24, y: start.y + 20))] {
        CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.1)
    }
    try wait("Native frame drag did not move the window") {
        guard let moved = bounds(window) else { return false }
        return abs(moved.minX - dragFrame.minX) >= 10 || abs(moved.minY - dragFrame.minY) >= 10
    }
    results["native_drag_passed"] = true
    if let moved = bounds(window) { _ = try capture("dragged", frame: moved) }
    // Focus the other synthetic page to qualify an inactive native window
    // without depending on macOS permitting activation of an unrelated app.
    try fixtureControl("split")
    try fixtureControl("focus", peer: true)
    try wait("Peer fixture window did not gain focus") {
        guard let focused = value(app, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        return !CFEqual(focused, window)
    }
    Thread.sleep(forTimeInterval: 0.3)
    if let resized = bounds(window) { _ = try capture("inactive", frame: resized) }
    results["inactive_capture_passed"] = true
    try fixtureControl("focus")
    results["passed"] = true
} catch {
    results["error"] = String(describing: error)
    if let inspectedField {
        results["failure_address"] = value(inspectedField, kAXValueAttribute) as? String
        results["failure_selection"] = value(inspectedField, kAXSelectedTextAttribute) as? String
    }
    if let inspectedWindow, let frame = bounds(inspectedWindow) {
        results["failure_title"] = value(inspectedWindow, kAXTitleAttribute) as? String
        _ = try? capture("failure", frame: frame)
    }
}
if changedClipboard {
    clipboard.clearContents()
    let items = savedClipboard.map { data -> NSPasteboardItem in
        let item = NSPasteboardItem(); for (type, bytes) in data { item.setData(bytes, forType: type) }; return item
    }
    clipboard.writeObjects(items)
}
previousApp?.activate(options: [])
let report = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
try report.write(to: output.appendingPathComponent("input-result.json"))
print(String(decoding: report, as: UTF8.self))
exit(results["passed"] as? Bool == true ? 0 : 1)
