// Read-only benchmark context. No AX, window titles, browser contents, screenshots,
// activation, input events, process arguments, or power-setting changes.
// Build: swiftc -O -parse-as-library -swift-version 6 observe_environment.swift -o observe-environment
import AppKit
import CryptoKit
import Darwin
import Foundation
import IOKit.ps

struct ProcessIdentity: Equatable {
    let seconds: UInt64
    let microseconds: UInt64
    let path: String
}

func identity(_ pid: Int32) -> ProcessIdentity? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
          info.pbi_flags & UInt32(PROC_FLAG_INEXIT) == 0 else { return nil }
    var path = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    return ProcessIdentity(seconds: info.pbi_start_tvsec,
                           microseconds: info.pbi_start_tvusec,
                           path: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
}

func digest(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

func displays() -> [[String: Any]] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).sorted().map { id in
        let bounds = CGDisplayBounds(id)
        guard let mode = CGDisplayCopyDisplayMode(id) else { return ["id": id, "mode_available": false] }
        return ["id": id, "mode_available": true, "x": bounds.minX, "y": bounds.minY,
                "width_points": bounds.width, "height_points": bounds.height,
                "width_pixels": mode.pixelWidth, "height_pixels": mode.pixelHeight,
                "refresh_hz": mode.refreshRate]
    }
}

@MainActor
final class Recorder {
    let pid: Int32
    let expected: ProcessIdentity
    let handle: FileHandle
    let interval: Double
    let seconds: Double
    var timebase = mach_timebase_info_data_t()
    var observers: [(NotificationCenter, NSObjectProtocol)] = []
    var writeFailed = false

    init(pid: Int32, expected: ProcessIdentity, output: String, interval: Double, seconds: Double) throws {
        self.pid = pid
        self.expected = expected
        self.interval = interval
        self.seconds = seconds
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else {
            throw NSError(domain: "MachClock", code: 1)
        }
        let fd = open(output, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func ns(_ ticks: UInt64) -> UInt64 {
        // Quotient/remainder conversion avoids overflowing ticks * numerator.
        let denominator = UInt64(timebase.denom), numerator = UInt64(timebase.numer)
        return (ticks / denominator) * numerator + (ticks % denominator) * numerator / denominator
    }

    func emit(_ value: [String: Any]) {
        guard !writeFailed else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            data.append(0x0a)
            try handle.write(contentsOf: data)
        } catch { writeFailed = true }
    }

    func record(_ reason: String, activatedTarget: Bool? = nil) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var source: Any = NSNull()
        if let power = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let provider = IOPSGetProvidingPowerSourceType(power)?.takeUnretainedValue() {
            source = provider as String
        }
        var item: [String: Any] = [
            "type": "sample", "reason": reason,
            "continuous_ns": ns(mach_continuous_time()), "awake_ns": ns(mach_absolute_time()),
            "target_identity_matches": identity(pid) == expected,
            "target_foreground": frontmost.map { ($0 == pid) as Any } ?? NSNull(),
            "thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
            "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "power_source": source, "displays": displays()
        ]
        if let activatedTarget { item["activated_target"] = activatedTarget }
        emit(item)
    }

    func observe(_ center: NotificationCenter, _ name: Notification.Name, reason: String) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            // NotificationCenter's main operation queue executes on the main actor.
            let appPID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                self.record(reason, activatedTarget: appPID.map { $0 == self.pid })
            }
        }
        observers.append((center, token))
    }

    func run() throws {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        emit(["type": "metadata", "schema_version": 1, "scope": "benchmark_environment_observation_only",
              "recorded_utc": ISO8601DateFormatter().string(from: Date()),
              "target_pid": pid, "target_executable": expected.path,
              "target_executable_sha256": try digest(URL(fileURLWithPath: expected.path)),
              "collector_executable_sha256": try digest(binary),
              "requested_seconds": seconds, "interval_seconds": interval,
              "mach_timebase": ["numer": timebase.numer, "denom": timebase.denom],
              "os": ProcessInfo.processInfo.operatingSystemVersionString,
              "memory_bytes": ProcessInfo.processInfo.physicalMemory,
              "logical_cpus": ProcessInfo.processInfo.processorCount,
              "limits": ["App foreground is not tab/window focus or presented content",
                         "Does not measure benchmark scores or close background applications",
                         "Refresh rate zero means unknown/variable, not a measured cadence",
                         "Notifications and periodic samples may miss events; no milestone qualification"]])
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification, reason: "activation")
        observe(workspace, NSWorkspace.willSleepNotification, reason: "will_sleep")
        observe(workspace, NSWorkspace.didWakeNotification, reason: "did_wake")
        _ = ProcessInfo.processInfo.thermalState // Required before registering for thermal notifications.
        observe(.default, ProcessInfo.thermalStateDidChangeNotification, reason: "thermal_change")
        observe(.default, Notification.Name.NSProcessInfoPowerStateDidChange, reason: "power_change")
        record("start")
        let start = ns(mach_continuous_time())
        let deadline = start + UInt64(seconds * 1e9)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.record("interval") }
        }
        RunLoop.current.add(timer, forMode: .default)
        while !writeFailed && ns(mach_continuous_time()) < deadline {
            let now = ns(mach_continuous_time())
            let wait = Double(deadline - min(now, deadline)) / 1e9
            RunLoop.current.run(until: Date(timeIntervalSinceNow: wait))
        }
        timer.invalidate()
        record("end")
        for (center, token) in observers { center.removeObserver(token) }
        emit(["type": "completion", "complete": !writeFailed,
              "target_identity_matches": identity(pid) == expected,
              "target_executable_sha256": try digest(URL(fileURLWithPath: expected.path))])
        try handle.close()
        if writeFailed { throw NSError(domain: "ObservationWrite", code: 1) }
    }
}

@main
struct Main {
    @MainActor static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let allowed: Set<String> = ["--pid", "--executable", "--output", "--seconds", "--interval"]
            guard args.count % 2 == 0 else { throw NSError(domain: "Arguments", code: 1) }
            var options: [String: String] = [:]
            for i in stride(from: 0, to: args.count, by: 2) {
                guard allowed.contains(args[i]), options[args[i]] == nil else { throw NSError(domain: "Arguments", code: 2) }
                options[args[i]] = args[i + 1]
            }
            guard let pidText = options["--pid"], let pid = Int32(pidText), pid > 0,
                  let path = options["--executable"], let output = options["--output"],
                  let seconds = Double(options["--seconds"] ?? "600"), seconds.isFinite, seconds > 0, seconds <= 3600,
                  let interval = Double(options["--interval"] ?? "2"), interval.isFinite, interval >= 0.25,
                  interval <= min(10, seconds), let expected = identity(pid),
                  expected.path == URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            else { throw NSError(domain: "ArgumentsOrTargetIdentity", code: 3) }
            try Recorder(pid: pid, expected: expected, output: output, interval: interval, seconds: seconds).run()
        } catch {
            FileHandle.standardError.write(Data("Environment observation failed: \(error)\nUsage: observe-environment --pid PID --executable PATH --output NEW.jsonl [--seconds 600 --interval 2]\n".utf8))
            exit(1)
        }
    }
}
