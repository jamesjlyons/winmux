import AppKit
import ApplicationServices
// Read-only observation of the supplied fixture PID. No titles or content.
@_silgen_name("_AXUIElementGetWindow") func windowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func id(_ element: AXUIElement) -> UInt32 { var id: UInt32 = 0; _ = windowID(element, &id); return id }
guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]), pid > 0 else { exit(2) }
guard AXIsProcessTrusted() else { fputs("Accessibility access unavailable\n", stderr); exit(3) }
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 0.5)
var known: [UInt32: AXUIElement] = [:]
var groups: [AXUIElement] = []
func groupIdentity(_ group: AXUIElement) -> Int {
    if let index = groups.firstIndex(where: { CFEqual($0, group) }) { return index }
    groups.append(group)
    return groups.count - 1
}
for tick in 0..<14 {
    let current = attr(app, "AXWindows") as? [AXUIElement] ?? []
    for window in current { known[id(window)] = window }
    let reports = known.sorted { $0.key < $1.key }.map { key, window -> [String: Any] in
        let children = attr(window, "AXChildren") as? [AXUIElement] ?? []
        let tabgroups = children.filter { attr($0, "AXRole") as? String == "AXTabGroup" }
        return ["originalID": key, "currentID": id(window), "enumerated": current.contains { CFEqual($0, window) },
                "tabgroups": tabgroups.map { group -> [String: Any] in
                    let tabs = attr(group, "AXTabs") as? [AXUIElement] ?? []
                    return ["identity": groupIdentity(group), "hash": CFHash(group), "id": id(group), "tabs": tabs.map {
                        ["hash": CFHash($0), "id": id($0), "value": attr($0, "AXValue") as? Int ?? -1]
                    }]
                }]
    }
    print(String(data: try JSONSerialization.data(withJSONObject: ["tick": tick, "windows": reports], options: [.sortedKeys]), encoding: .utf8)!)
    fflush(stdout); Thread.sleep(forTimeInterval: 1)
}
