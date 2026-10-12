import SwiftUI

/// Owned as a reference in the sidebar's State; only the offset modifier
/// subscribes. Discrete page/direction changes still belong to the sidebar.
@MainActor
final class WorkspaceSidebarProjectSwipePosition: ObservableObject {
    @Published private(set) var translation: CGFloat = 0

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
