import Foundation

/// One queued delivery per display source, regardless of how long the main actor is busy.
/// Generations prevent callbacks queued before stop/restart from reaching new subscribers.
final class DisplayFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var active = false
    private var pendingTimestamp: TimeInterval?

    func start() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        active = true
        pendingTimestamp = nil
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        active = false
        pendingTimestamp = nil
    }

    func submit(_ timestamp: TimeInterval) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return nil }
        let needsDelivery = pendingTimestamp == nil
        pendingTimestamp = max(pendingTimestamp ?? timestamp, timestamp)
        return needsDelivery ? generation : nil
    }

    func take(generation expected: UInt64) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard active, generation == expected else { return nil }
        defer { pendingTimestamp = nil }
        return pendingTimestamp
    }
}
