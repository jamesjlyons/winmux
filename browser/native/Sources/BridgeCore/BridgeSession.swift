import Foundation

/// Per-connection state, protected because NSXPC callbacks are not main-actor work.
/// A reconnect creates a new object and epoch. Old messages cannot authenticate it.
public final class BridgeSession: @unchecked Sendable {
    public static let version = 1
    private let lock = NSLock()
    private let epoch = UUID().uuidString
    private var negotiated = false
    private var lastSequence: UInt64 = 0

    public init() {}

    public func negotiate(version: Int) -> String? {
        lock.withLock {
            guard version == Self.version else { return nil }
            negotiated = true
            return epoch
        }
    }

    public func accept(epoch: String, sequence: UInt64) -> Bool {
        lock.withLock {
            guard negotiated, epoch == self.epoch, sequence > lastSequence else { return false }
            lastSequence = sequence
            return true
        }
    }
}
