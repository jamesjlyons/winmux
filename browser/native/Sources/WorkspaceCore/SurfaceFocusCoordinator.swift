import Foundation

/// One user-intent clock across native windows and all browser connections.
/// A dispatch acknowledgement never promotes an intent to input-ready focus.
@MainActor
public final class SurfaceFocusCoordinator {
    public private(set) var generation: UInt64 = 0
    public private(set) var target: SurfaceID?
    public init() {}

    public func select(_ target: SurfaceID?) -> UInt64? {
        guard generation < .max else { return nil }
        generation += 1
        self.target = target
        return generation
    }

    public func isCurrent(_ generation: UInt64, target: SurfaceID) -> Bool {
        self.generation == generation && self.target == target
    }
}
