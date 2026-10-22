import AppKit

extension Monitor {
    @MainActor
    var workspaceSidebarInset: CGFloat {
        guard config.workspaceSidebar.enabled,
              !shouldSuppressWorkspaceSidebarForFullscreenContent(on: self)
        else { return 0 }
        return workspaceSidebarResolvedPanelMonitors().contains { $0.rect.topLeftCorner == rect.topLeftCorner }
            ? workspaceSidebarReservedWidth(config.workspaceSidebar, screenWidth: rect.width)
            : 0
    }

    @MainActor
    var workspaceTopBarInset: CGFloat {
        guard config.workspaceSidebar.enabled, config.workspaceSidebar.placement == .top,
              !shouldSuppressWorkspaceSidebarForFullscreenContent(on: self),
              workspaceSidebarResolvedPanelMonitors().contains(where: { $0.rect.topLeftCorner == rect.topLeftCorner })
        else { return 0 }
        return workspaceTopBarReservedHeight(config.workspaceSidebar, visibleHeight: visibleRect.height,
            menuBarHeight: max(0, visibleRect.topLeftY - rect.topLeftY))
    }

    @MainActor
    var visibleRectPaddedByOuterGaps: Rect {
        let topLeft = visibleRect.topLeftCorner
        let gaps = ResolvedGaps(gaps: config.gaps, monitor: self)
        let leftInset = gaps.outer.left.toDouble() + workspaceSidebarInset
        let topInset = gaps.outer.top.toDouble() + workspaceTopBarInset
        return Rect(
            topLeftX: topLeft.x + leftInset,
            topLeftY: topLeft.y + topInset,
            width: visibleRect.width - leftInset - gaps.outer.right.toDouble(),
            height: visibleRect.height - topInset - gaps.outer.bottom.toDouble(),
        )
    }

    @MainActor
    var monitorId_oneBased: Int? {
        sortedMonitors.firstIndex { $0.rect.topLeftCorner == rect.topLeftCorner }.map { $0 + 1 }
    }
}
