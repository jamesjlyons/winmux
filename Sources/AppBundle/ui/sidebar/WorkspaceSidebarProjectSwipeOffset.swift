import SwiftUI

/// Owned as a reference in the sidebar's State; only the offset modifier
/// subscribes to `translation`. The remaining fields are gesture bookkeeping
/// that the body never needs: they deliberately do not publish, so locking a
/// direction, crossing the switch threshold and releasing the fingers cannot
/// re-evaluate every page and row while the strip is moving.
@MainActor
final class WorkspaceSidebarProjectSwipePosition: ObservableObject {
    @Published private(set) var translation: CGFloat = 0
    var direction: Int?
    var settlement: WorkspaceSidebarProjectSwipeSettlement?
    var didCrossBreakPoint = false

    func move(to translation: CGFloat) {
        guard self.translation != translation else { return }
        self.translation = translation
    }
}

struct WorkspaceSidebarProjectSwipeOffset: ViewModifier {
    @ObservedObject var position: WorkspaceSidebarProjectSwipePosition
    let displayIndex: Int
    let projectCount: Int
    let pageWidth: CGFloat

    func body(content: Content) -> some View {
        let dragOffset = workspaceSidebarProjectPagerDragOffset(
            horizontalTranslation: position.translation,
            currentIndex: displayIndex,
            projectCount: projectCount,
            pageWidth: pageWidth
        )
        content.offset(x: -CGFloat(displayIndex) * pageWidth + dragOffset)
    }
}
