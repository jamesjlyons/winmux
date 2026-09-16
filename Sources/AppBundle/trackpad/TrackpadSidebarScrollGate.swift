import AppKit

/// Once raw three-finger input owns a scroll sequence, also swallow its release
/// and momentum. Only a fresh scroll gesture may enter sidebar navigation again.
struct TrackpadSidebarScrollGate {
    private var suppressing = false

    mutating func shouldSuppress(owned: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase) -> Bool {
        if owned { suppressing = true }
        else if momentum.isEmpty && (phase.contains(.began) || phase.contains(.mayBegin)) { suppressing = false }
        return suppressing
    }
}
