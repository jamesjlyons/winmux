import AppKit
import Foundation
while readLine() != nil {
    let windows = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    let items = windows.compactMap { w -> [String: Any]? in
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let id = w[kCGWindowNumber as String], let pid = w[kCGWindowOwnerPID as String],
              let bounds = w[kCGWindowBounds as String] else { return nil }
        return ["id": id, "pid": pid, "bounds": bounds, "onscreen": w[kCGWindowIsOnscreen as String] ?? false]
    }
    let data = try! JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    fflush(stdout)
}
