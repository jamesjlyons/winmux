import Foundation

/// The browser's TimeTicks and DispatchTime use the same macOS monotonic clock.
/// No page URL, title, or profile name is written to diagnostics.
public enum BrowserTabTiming {
    public static let enabled = ProcessInfo.processInfo.environment["WINMUX_TRACE_TABS"] == "1"
    public static var now: UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000 }
    public static func record(_ stage: String, operation: UUID, at: UInt64? = nil) {
        guard enabled else { return }
        NSLog("WINMUX_TAB_TIMING {\"operation\":\"%@\",\"stage\":\"%@\",\"time_us\":%llu}",
              operation.uuidString.lowercased(), stage, at ?? now)
    }
}
