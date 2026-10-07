import AppKit

func workspaceSidebarKeepsExpandedAtRest(_ sidebarConfig: WorkspaceSidebarConfig) -> Bool {
    sidebarConfig.visibility == .expanded
}

func workspaceSidebarAllowsLeftEdgeTrap(_ sidebarConfig: WorkspaceSidebarConfig) -> Bool {
    !workspaceSidebarKeepsExpandedAtRest(sidebarConfig)
}

func workspaceSidebarRestingWidth(_ sidebarConfig: WorkspaceSidebarConfig) -> CGFloat {
    switch sidebarConfig.visibility {
    case .autoHide: 0
    case .expanded: CGFloat(sidebarConfig.width)
    case .compact: CGFloat(sidebarConfig.collapsedWidth)
    }
}

func workspaceSidebarHoverActivationWidth(_ sidebarConfig: WorkspaceSidebarConfig) -> CGFloat {
    workspaceSidebarKeepsExpandedAtRest(sidebarConfig) ? CGFloat(sidebarConfig.width) : CGFloat(sidebarConfig.collapsedWidth)
}

func workspaceSidebarCollapsedContentWidth(_ sidebarConfig: WorkspaceSidebarConfig) -> CGFloat {
    sidebarConfig.visibility == .autoHide ? 0 : CGFloat(sidebarConfig.collapsedWidth)
}

func isWorkspaceSidebarHoverDeepEnoughToExpand(
    mouseX: CGFloat,
    sidebarMinX: CGFloat,
    collapsedWidth: CGFloat,
) -> Bool {
    guard collapsedWidth > 0 else { return false }
    let sidebarMaxX = sidebarMinX + collapsedWidth
    return sidebarMaxX - mouseX >= collapsedWidth * workspaceSidebarHoverOpenThresholdFraction
}

func shouldDelayWorkspaceSidebarExpansion(
    isExpanded: Bool,
    isExpansionLocked: Bool,
    isMouseWindowDragInProgress: Bool,
) -> Bool {
    !isExpanded && !isExpansionLocked && !isMouseWindowDragInProgress
}

func shouldSuppressWorkspaceSidebarHoverExpansionForDrag(
    isSidebarItemDragActive: Bool,
    isSidebarOriginatedDrag: Bool,
) -> Bool {
    isSidebarItemDragActive || isSidebarOriginatedDrag
}
