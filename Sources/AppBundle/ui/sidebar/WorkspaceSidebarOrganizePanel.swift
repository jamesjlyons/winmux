import AppKit
import SwiftUI

extension WorkspaceSidebarPanel {
    var expandedPresentationWidth: CGFloat {
        let width = CGFloat(config.workspaceSidebar.width)
        let available = workspaceSidebarPanelScreen()?.frame.width ?? width
        guard viewModel.workspaceSidebarBrowseMode == .organize else { return min(width, available) }
        return WorkspaceSidebarOrganizeLayout(
            expandedWidth: width,
            projectCount: viewModel.workspaceSidebarProjects.count,
            availableWidth: available
        ).visibleWidth
    }

    func setBrowseMode(_ mode: WorkspaceSidebarBrowseMode) {
        guard viewModel.workspaceSidebarBrowseMode != mode else { return }
        cancelExpansionWork()
        viewModel.workspaceSidebarBrowseMode = mode
        viewModel.isWorkspaceSidebarExpanded = true
        organizeCollapseSuppressedUntil = mode == .organize ? Date().addingTimeInterval(0.65) : .distantPast
        if let layout = currentSidebarPanelLayout() {
            setFrame(layout.frame, display: true, animate: false)
        }
        updateDropTargets([])
        animateVisibleSidebarWidth(expandedPresentationWidth, animation: workspaceSidebarExpansionAnimation)
    }

    func resetBrowseMode() {
        viewModel.setIfChanged(\.workspaceSidebarBrowseMode, .activeProject)
        organizeCollapseSuppressedUntil = .distantPast
    }
}
