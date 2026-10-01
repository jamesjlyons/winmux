import Foundation

/// Per-connection state, protected because NSXPC callbacks are not main-actor work.
/// A reconnect creates a new object and epoch. Old messages cannot authenticate it.
public final class BridgeSession: @unchecked Sendable {
    public static let version = 3
    private let lock = NSLock()
    private let epoch = UUID().uuidString
    private var negotiatedVersion: Int?
    private var lastSequence: UInt64 = 0

    public init() {}

    public func negotiate(version: Int) -> String? {
        lock.withLock {
            guard (1...Self.version).contains(version),
                  negotiatedVersion == nil || negotiatedVersion == version else { return nil }
            negotiatedVersion = version
            return epoch
        }
    }

    public var version: Int? { lock.withLock { negotiatedVersion } }

    public func accept(epoch: String, sequence: UInt64, minimumVersion: Int = 1) -> Bool {
        lock.withLock {
            guard let negotiatedVersion, negotiatedVersion >= minimumVersion,
                  epoch == self.epoch, sequence > lastSequence else { return false }
            lastSequence = sequence
            return true
        }
    }
}
