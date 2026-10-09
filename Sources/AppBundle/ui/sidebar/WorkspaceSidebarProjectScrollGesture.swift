import AppKit

/// A finger-down sequence owns at most one page change. Its momentum is consumed
/// until the next gesture, and pauses in phased input never count as a release.
struct WorkspaceSidebarProjectScrollGesture {
    enum Update: Equatable {
        case passThrough
        case consumed
        case changed(CGFloat, CGFloat)
        case ended(CGFloat, CGFloat)
    }

    private var horizontal: CGFloat = 0
    private var vertical: CGFloat = 0
    private var isTracking = false
    private var isPhased = false
    private(set) var suppressMomentum = false
    private(set) var isLocked = false

    var needsEndTimer: Bool { isLocked && !isPhased }

    mutating func update(deltaX: CGFloat, deltaY: CGFloat, phase: NSEvent.Phase, momentum: NSEvent.Phase) -> Update {
        guard momentum.isEmpty else {
            // Some input sources transition straight into momentum. Finish using
            // finger travel only, even when release and momentum share an event.
            if isLocked && (momentum.contains(.began) || phase.contains(.ended) || phase.contains(.cancelled)) {
                return finish(cancelled: phase.contains(.cancelled))
            }
            return suppressMomentum ? .consumed : .passThrough
        }
        if phase.contains(.began) || phase.contains(.mayBegin) {
            self = Self()
            isTracking = true
            isPhased = true
        } else if phase.isEmpty && !isTracking && !isPhased {
            isTracking = true
        }
        guard isTracking else { return suppressMomentum ? .consumed : .passThrough }
        if phase.contains(.cancelled) { return finish(cancelled: true) }
        horizontal = workspaceSidebarProjectSwipeTranslationAfterScroll(currentTranslation: horizontal, scrollingDeltaX: deltaX)
        vertical += deltaY
        if !isLocked {
            isLocked = workspaceSidebarProjectSwipeDirection(horizontalTranslation: horizontal, verticalTranslation: vertical) != nil
            if isLocked { suppressMomentum = true }
        }
        if phase.contains(.ended) { return finish() }
        return isLocked ? .changed(horizontal, vertical) : .passThrough
    }

    mutating func finish(cancelled: Bool = false) -> Update {
        let result: Update = isLocked ? .ended(cancelled ? 0 : horizontal, cancelled ? 0 : vertical) : .passThrough
        horizontal = 0
        vertical = 0
        isTracking = false
        isLocked = false
        return result
    }
}
