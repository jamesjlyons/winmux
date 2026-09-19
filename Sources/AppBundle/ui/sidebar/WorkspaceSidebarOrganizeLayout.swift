import Foundation

/// The saved sidebar width remains the width of one column, including its outer insets.
struct WorkspaceSidebarOrganizeLayout: Equatable {
    static let gap: CGFloat = 8
    static let inset: CGFloat = 12
    let columnWidth: CGFloat
    let contentWidth: CGFloat
    let visibleWidth: CGFloat

    init(expandedWidth: CGFloat, projectCount: Int, availableWidth: CGFloat) {
        let count = CGFloat(max(projectCount, 1))
        columnWidth = max(0, expandedWidth - Self.inset * 2)
        contentWidth = Self.inset * 2 + count * columnWidth + (count - 1) * Self.gap
        visibleWidth = min(contentWidth, max(0, availableWidth))
    }
}

func workspaceSidebarOrganizeScrollStep(pointerX: CGFloat, viewportWidth: CGFloat) -> CGFloat {
    let edge = min(36, viewportWidth / 4)
    guard edge > 0, pointerX >= 0, pointerX <= viewportWidth else { return 0 }
    if pointerX < edge { return -10 * (1 - pointerX / edge) }
    if pointerX > viewportWidth - edge { return 10 * (1 - (viewportWidth - pointerX) / edge) }
    return 0
}
