import AppKit
import Common

/// Keep the exact pre-parking frame. Proportional placement is only needed when
/// the destination monitor changes; ordinary group switches must not clamp or
/// round a user's existing placement, including windows across monitor edges.
struct WindowParkingSnapshot {
    let frame: Rect
    let monitorRect: Rect

    func restoredFrame(on destination: Rect) -> Rect {
        guard destination != monitorRect else { return frame }
        let xRatio = monitorRect.width > 0 ? (frame.minX - monitorRect.minX) / monitorRect.width : 0
        let yRatio = monitorRect.height > 0 ? (frame.minY - monitorRect.minY) / monitorRect.height : 0
        let x = (destination.minX + destination.width * xRatio)
            .coerce(in: destination.minX ... max(destination.minX, destination.maxX - frame.width))
        let y = (destination.minY + destination.height * yRatio)
            .coerce(in: destination.minY ... max(destination.minY, destination.maxY - frame.height))
        return Rect(topLeftX: x, topLeftY: y, width: frame.width, height: frame.height)
    }
}

extension Window {
    @MainActor
    func restoreFloatingFrame(_ snapshot: WindowParkingSnapshot, on monitorRect: Rect, restoreSize: Bool = true) {
        let frame = snapshot.restoredFrame(on: monitorRect)
        restoredFloatingFrameMonitorRect = monitorRect
        // A tiling-to-floating command may have chosen a new size while parked.
        setAxFrame(frame.topLeftCorner, restoreSize ? frame.size : nil)
    }
}
