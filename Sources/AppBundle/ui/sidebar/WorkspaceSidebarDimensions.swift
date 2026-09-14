import SwiftUI

@MainActor
func workspaceSidebarCompactSectionWidth(layout: WorkspaceSidebarConfiguration) -> CGFloat {
    max(
        layout.collapsedWidth - (workspaceSidebarCompactHorizontalInset(collapsedWidth: layout.collapsedWidth) * 2),
        0,
    )
}

/// Compact controls share the space available inside the rail, including at 28 points.
struct WorkspaceSidebarCompactMetrics {
    let sectionWidth: CGFloat

    var horizontalInset: CGFloat { min(workspaceSidebarSectionInnerHorizontalInset, max(0, (sectionWidth - 18) / 2)) }
    var badgeWidth: CGFloat { min(workspaceSidebarBadgeWidth, max(0, sectionWidth - horizontalInset * 2)) }
    var badgeFontSize: CGFloat { min(16, max(1, badgeWidth * 0.72)) }
    var controlHeight: CGFloat { min(38, max(28, sectionWidth + 6)) }
    var cornerRadius: CGFloat { min(workspaceSidebarSectionCornerRadius, max(0, sectionWidth / 3)) }
}

@MainActor
func workspaceSidebarExpandedSectionWidth(layout: WorkspaceSidebarConfiguration) -> CGFloat {
    max(
        layout.expandedWidth -
            workspaceSidebarContentLeadingInset -
            workspaceSidebarContentTrailingInset,
        workspaceSidebarCompactSectionWidth(layout: layout),
    )
}

@MainActor
func workspaceSidebarSectionWidth(_ expansionProgress: CGFloat, layout: WorkspaceSidebarConfiguration) -> CGFloat {
    let compact = workspaceSidebarCompactSectionWidth(layout: layout)
    let expanded = workspaceSidebarExpandedSectionWidth(layout: layout)
    return compact + (expanded - compact) * expansionProgress
}

@MainActor
func workspaceSidebarContentWidth(_ expansionProgress: CGFloat, layout: WorkspaceSidebarConfiguration) -> CGFloat {
    max(
        workspaceSidebarSectionWidth(expansionProgress, layout: layout) -
            (workspaceSidebarSectionInnerHorizontalInset * 2) -
            workspaceSidebarBadgeWidth -
            workspaceSidebarHeaderSpacing,
        0,
    )
}
