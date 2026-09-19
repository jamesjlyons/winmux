import SwiftUI

func workspaceSidebarCompactHorizontalInset(collapsedWidth: CGFloat) -> CGFloat {
    min(workspaceSidebarCompactRailHorizontalInset, max(0, (collapsedWidth / 10).rounded()))
}

func workspaceSidebarOuterLeadingPadding(expansionProgress: CGFloat, layout: WorkspaceSidebarConfiguration) -> CGFloat {
    let compact = workspaceSidebarCompactHorizontalInset(collapsedWidth: layout.collapsedWidth)
    return compact + (workspaceSidebarContentLeadingInset - compact) * expansionProgress
}

func workspaceSidebarOuterTrailingPadding(expansionProgress: CGFloat, layout: WorkspaceSidebarConfiguration) -> CGFloat {
    let compact = workspaceSidebarCompactHorizontalInset(collapsedWidth: layout.collapsedWidth)
    return compact + (workspaceSidebarContentTrailingInset - compact) * expansionProgress
}

func workspaceSidebarFooterBottomPadding(showsClock: Bool) -> CGFloat {
    showsClock ? 0 : 6
}

func workspaceSidebarHoverCueWidth(collapsedWidth: CGFloat, expandedWidth: CGFloat) -> CGFloat {
    min(collapsedWidth, expandedWidth)
}
