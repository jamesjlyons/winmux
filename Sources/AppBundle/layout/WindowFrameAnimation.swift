import Foundation

/// Analytic critically damped springs: stable at any display refresh rate, with
/// continuous position and velocity when a new layout interrupts the old one.
/// Inspired by Dinky's AX frame animation approach (see docs/window-animations.md).
struct WindowFrameAnimation {
    private(set) var target: CGRect
    private var value: SIMD4<Double>
    private var velocity = SIMD4<Double>.zero
    private var elapsed = 0.0

    init(from start: CGRect, to target: CGRect) {
        self.target = target
        value = Self.components(start)
    }

    var frame: CGRect {
        CGRect(x: value[0].rounded(), y: value[1].rounded(),
               width: max(1, value[2].rounded()), height: max(1, value[3].rounded()))
    }

    mutating func retarget(_ target: CGRect) {
        guard target != self.target else { return }
        self.target = target
        elapsed = 0
    }

    /// Returns true on arrival. The caller applies the exact target with the
    /// ordinary verified AX writer once, including any fractional coordinates.
    mutating func advance(by dt: TimeInterval, duration: TimeInterval) -> Bool {
        guard dt.isFinite, dt >= 0, duration > 0 else { return true }
        elapsed += dt
        let goal = Self.components(target)
        if elapsed >= max(0.25, duration * 3) { return true }
        let omega = 8 / duration
        let displacement = value - goal
        let coefficient = velocity + displacement * omega
        let decay = exp(-omega * dt)
        value = goal + (displacement + coefficient * dt) * decay
        velocity = (velocity - coefficient * (omega * dt)) * decay
        return (0..<4).allSatisfy { abs(value[$0] - goal[$0]) < 0.5 && abs(velocity[$0]) < 8 }
    }

    private static func components(_ rect: CGRect) -> SIMD4<Double> {
        .init(rect.origin.x, rect.origin.y, rect.width, rect.height)
    }
}

extension Rect {
    /// AX coordinates already have a top-left origin; do not use CGRect.toRect(),
    /// which converts an AppKit bottom-left origin.
    var axAnimationFrame: CGRect { CGRect(origin: topLeftCorner, size: size) }
}
