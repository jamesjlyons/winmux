#if DEBUG
import CoreGraphics

/// Test-only seams. The hosted sidebar fixtures count body evaluations and drive
/// the Space swipe through the same handlers the scroll capture calls, so the
/// render work of a gesture can be asserted without synthesizing input events.
@MainActor
enum WorkspaceSidebarViewTestHooks {
    static var bodyEvaluations = 0
    static var swipeDriver: WorkspaceSidebarSwipeDriver?
    /// Stands in for the pointer resting over the sidebar, which a hosted fixture cannot provide.
    static var forcesAdjacentPageMounting: Bool?
}

struct WorkspaceSidebarSwipeDriver {
    let changed: @MainActor (CGFloat, CGFloat) -> Void
    let ended: @MainActor (CGFloat, CGFloat) -> Void
}
#endif
