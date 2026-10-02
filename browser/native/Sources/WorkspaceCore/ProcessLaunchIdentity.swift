import Darwin
import Foundation

/// Launch Services does not supply launchDate for every directly launched app.
/// The kernel start timestamp exists independently of how the app was started.
public func processLaunchDate(_ pid: Int32) -> Date? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_start_tvsec > 0 else { return nil }
    return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
}
