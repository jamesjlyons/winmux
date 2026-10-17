import AppKit
import ApplicationServices
@_silgen_name("_AXUIElementGetWindow") func nativeID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
extension AXUIElement {
    func containingWindowId() -> UInt32? {
        var id: UInt32 = 0
        return nativeID(self, &id) == .success && id != 0 ? id : nil
    }
}
func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, n as CFString, &value) == .success ? value : nil
}
guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]), AXIsProcessTrusted() else { exit(2) }
let app = AXUIElementCreateApplication(pid), native = NativeTabAccessibility()
var known: [UInt32: AXUIElement] = [:]
for tick in 0..<31 {
    let enumerated = attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    known = known.filter { $0.value.containingWindowId() != nil }
    for window in enumerated {
        guard let id = window.containingWindowId() else { continue }
        known[id] = window; native.observe(window, id: id)
    }
    for (id, window) in native.refreshKnownGroups() { known[id] = window }
    native.retainAlive(Set(known.keys))
    let selected = native.registry.selectedByMember
    let report: [String: Any] = ["tick": tick, "time": ProcessInfo.processInfo.systemUptime,
        "logical": Set(known.keys.map { selected[$0] ?? $0 }).sorted(),
        "enumerated": enumerated.compactMap { $0.containingWindowId() }.sorted(),
        "groups": native.registry.groups.values.map {
            ["identity": $0.id.uuidString, "selected": $0.selectedWindowID,
             "members": $0.memberWindowIDs.sorted(), "count": max($0.count, 1)] as [String: Any]
        }]
    print(String(data: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
    fflush(stdout); Thread.sleep(forTimeInterval: 0.5)
}
