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

func workspaceSidebarReservedWidth(_ sidebarConfig: WorkspaceSidebarConfig, screenWidth: CGFloat) -> CGFloat {
    let width = workspaceSidebarRestingWidth(sidebarConfig)
    guard width > 0 else { return 0 }
    return min(width + workspaceSidebarEffectiveEdgeGap(sidebarConfig, screenWidth: screenWidth), max(screenWidth - 1, 0))
}

func workspaceSidebarEffectiveEdgeGap(_ sidebarConfig: WorkspaceSidebarConfig, screenWidth: CGFloat) -> CGFloat {
    min(CGFloat(sidebarConfig.edgeGap), max(screenWidth - CGFloat(sidebarConfig.width), 0))
}

func workspaceSidebarPanelFrame(screenFrame: CGRect, width: CGFloat, configuration: WorkspaceSidebarConfig) -> CGRect {
    let edgeGap = workspaceSidebarEffectiveEdgeGap(configuration, screenWidth: screenFrame.width)
    let topInset = min(CGFloat(configuration.menuBarReserveHeight) + CGFloat(configuration.topGap), max(screenFrame.height - 1, 0))
    let bottomInset = min(CGFloat(configuration.bottomGap), max(screenFrame.height - topInset - 1, 0))
    return CGRect(x: screenFrame.minX + edgeGap, y: screenFrame.minY + bottomInset,
        width: min(width, screenFrame.width - edgeGap), height: screenFrame.height - topInset - bottomInset)
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
