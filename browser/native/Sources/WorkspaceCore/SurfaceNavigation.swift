public enum SurfaceDirection: Sendable {
    case left, right, up, down

    public var isHorizontal: Bool { self == .left || self == .right }
    public var isPositive: Bool { self == .right || self == .down }
}

/// Keep directional focus in the current row or column when the layout wraps.
/// Primary-axis ties use the nearest orthogonal center, never tree order.
public func directionalSurface(from source: SurfacePlacement, others: [SurfacePlacement],
                               direction: SurfaceDirection, wrapping: Bool) -> SurfaceID? {
    func axis(_ placement: SurfacePlacement) -> Int {
        direction.isHorizontal ? placement.frame.x + placement.frame.width / 2
            : placement.frame.y + placement.frame.height / 2
    }
    func cross(_ placement: SurfacePlacement) -> (Int, Int) {
        direction.isHorizontal ? (placement.frame.y, placement.frame.y + placement.frame.height)
            : (placement.frame.x, placement.frame.x + placement.frame.width)
    }
    let sourceCross = cross(source)
    func alignment(_ placement: SurfacePlacement) -> (Int, Int) {
        let bounds = cross(placement)
        let overlaps = max(sourceCross.0, bounds.0) < min(sourceCross.1, bounds.1)
        return (overlaps ? 0 : 1, abs((bounds.0 + bounds.1) - (sourceCross.0 + sourceCross.1)))
    }
    let available = others.filter { $0.visible && $0.surfaceID != source.surfaceID }
    let forward = available.filter { direction.isPositive ? axis($0) > axis(source) : axis($0) < axis(source) }
    if let next = forward.min(by: {
        let left = alignment($0), right = alignment($1)
        return (left.0, abs(axis($0) - axis(source)), left.1)
            < (right.0, abs(axis($1) - axis(source)), right.1)
    }) { return next.surfaceID }
    guard wrapping else { return nil }
    return available.min(by: {
        let left = alignment($0), right = alignment($1)
        let leftEdge = direction.isPositive ? axis($0) : -axis($0)
        let rightEdge = direction.isPositive ? axis($1) : -axis($1)
        return (left.0, leftEdge, left.1) < (right.0, rightEdge, right.1)
    })?.surfaceID
}

