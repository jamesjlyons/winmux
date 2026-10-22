@testable import AppBundle
import AppKit
import Common
import XCTest

/// Fullscreen content turns the side sidebar into Auto-hide for as long as it is
/// in front, and the saved visibility returns as soon as it is not.
@MainActor
final class WorkspaceSidebarFullscreenAutoHideTest: XCTestCase {
    func testCompactSidebarPresentsAsAutoHideWhileFullscreenContentIsInFront() async {
        await withSidebar(visibility: .compact) { panel in
            let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
            panel.refresh(on: mainMonitor)
            XCTAssertFalse(panel.presentsAutoHideForFullscreen)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 28)

            window.isFullscreen = true
            panel.refresh(on: mainMonitor)
            XCTAssertTrue(panel.presentsAutoHideForFullscreen)
            XCTAssertEqual(panel.presentedSidebarConfig.visibility, .autoHide)
            XCTAssertEqual(panel.currentSidebarPanelLayout(on: mainMonitor)?.collapsedWidth, 0)
            XCTAssertTrue(panel.isVisible, "The panel stays ordered in so the edge can reveal it")
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 0)
            XCTAssertFalse(panel.viewModel.isWorkspaceSidebarExpanded)
            XCTAssertEqual(config.workspaceSidebar.visibility, .compact, "The saved mode is not rewritten")

            // The edge still reveals and hides it, like a configured Auto-hide sidebar.
            // Hover-enter supplies region membership; the depth check compares the
            // real pointer with the panel, so put the panel far to its right.
            panel.setFrame(CGRect(x: 100000, y: 100000, width: 280, height: 600), display: false)
            let guards = "lock=\(panel.shouldLockExpansionForSidebarDrag()) windowDrag=\(isMouseWindowDragInProgress()) " +
                "sidebarDrag=\(isWorkspaceSidebarDragInProgress()) startedInSidebar=\(getCurrentMouseDragStartedInSidebar()) " +
                "itemDrag=\(isWorkspaceSidebarItemDragActive()) surfaceDrag=\(currentWorkspaceSidebarSurfaceDragSubject() != nil) " +
                "pinnedDrag=\(hasPinnedDraggedWindow()) menu=\(panel.isMenuTrackingOrInGracePeriod()) editing=\(panel.inlineTextEditingActive) " +
                "picker=\(panel.projectIconPicker != nil) resizing=\(panel.isResizingSidebar) suppress=\(panel.commandSuppressesHoverExpansion)"
            panel.handleHoverEnter(expandedWidth: 280, collapsedWidth: 0)
            XCTAssertTrue(panel.viewModel.isWorkspaceSidebarExpanded, guards)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 280)
            panel.handleHoverExit(collapsedWidth: 0)
            XCTAssertNotNil(panel.pendingCollapse)
            panel.cancelExpansionWork()
            panel.viewModel.isWorkspaceSidebarExpanded = false
            panel.viewModel.workspaceSidebarVisibleWidth = 0

            window.isFullscreen = false
            panel.refresh(on: mainMonitor)
            XCTAssertFalse(panel.presentsAutoHideForFullscreen)
            XCTAssertEqual(panel.presentedSidebarConfig.visibility, .compact)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 28)
        }
    }

    func testExpandedSidebarCollapsesForFullscreenAndReexpandsAfterwards() async {
        await withSidebar(visibility: .expanded) { panel in
            let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
            panel.refresh(on: mainMonitor)
            XCTAssertTrue(panel.viewModel.isWorkspaceSidebarExpanded)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 280)

            window.isFullscreen = true
            panel.refresh(on: mainMonitor)
            XCTAssertFalse(panel.viewModel.isWorkspaceSidebarExpanded)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 0)
            XCTAssertFalse(workspaceSidebarKeepsExpandedAtRest(panel.presentedSidebarConfig))

            window.isFullscreen = false
            panel.refresh(on: mainMonitor)
            XCTAssertTrue(panel.viewModel.isWorkspaceSidebarExpanded)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 280)
            XCTAssertEqual(config.workspaceSidebar.visibility, .expanded)
        }
    }

    func testFocusedNativeFullscreenWindowPresentsAutoHideUntilFocusLeavesIt() async {
        await withSidebar(visibility: .compact) { panel in
            let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
            window.nativeIsMacosFullscreen = true
            await updateNativeFullscreenChromeSuppression(nativeFocused: window)
            panel.refresh(on: mainMonitor)
            XCTAssertTrue(panel.presentsAutoHideForFullscreen)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 0)

            // Focus moving to a window that is not fullscreen, or the fullscreen
            // window going away, both clear the native observation.
            let other = TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
            await updateNativeFullscreenChromeSuppression(nativeFocused: other)
            panel.refresh(on: mainMonitor)
            XCTAssertFalse(panel.presentsAutoHideForFullscreen)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 28)

            await updateNativeFullscreenChromeSuppression(nativeFocused: window)
            panel.refresh(on: mainMonitor)
            XCTAssertTrue(panel.presentsAutoHideForFullscreen)
            await updateNativeFullscreenChromeSuppression(nativeFocused: nil)
            panel.refresh(on: mainMonitor)
            XCTAssertFalse(panel.presentsAutoHideForFullscreen)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 28)
        }
    }

    func testTopPlacementStaysHiddenForFullscreenContent() async {
        await withSidebar(visibility: .compact) { panel in
            config.workspaceSidebar.placement = .top
            let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
            window.isFullscreen = true
            panel.refresh(on: mainMonitor)
            XCTAssertFalse(panel.presentsAutoHideForFullscreen)
            XCTAssertNil(panel.currentSidebarPanelLayout(on: mainMonitor))
            XCTAssertFalse(panel.isVisible)
        }
    }

    private func withSidebar(visibility: WorkspaceSidebarVisibility, _ body: @MainActor (WorkspaceSidebarPanel) async -> Void) async {
        setUpWorkspacesForTests()
        let panel = WorkspaceSidebarPanel.shared
        let oldConfig = config
        let oldWidth = panel.viewModel.workspaceSidebarVisibleWidth
        let oldExpanded = panel.viewModel.isWorkspaceSidebarExpanded
        let oldPersistent = panel.persistentExpansionWidth
        let oldPlacement = panel.lastNavigationPlacement
        let oldSuppression = shouldSuppressChromeForNativeFullscreenContent
        let oldFrame = panel.frame
        let oldMode = panel.viewModel.workspaceSidebarBrowseMode
        let oldOrganizeSuppression = panel.organizeCollapseSuppressedUntil
        let oldMenuDepth = panel.menuTrackingDepth
        let oldMenuGrace = panel.menuTrackingGraceUntil
        let oldCommandLock = panel.commandExpansionLocksCollapse
        let oldHoverSuppression = panel.commandSuppressesHoverExpansion
        let oldDropPreview = TrayMenuModel.shared.workspaceSidebarDropPreview
        defer {
            panel.cancelExpansionWork()
            panel.orderOut(nil)
            config = oldConfig
            panel.presentsAutoHideForFullscreen = false
            panel.persistentExpansionWidth = oldPersistent
            panel.lastNavigationPlacement = oldPlacement
            panel.viewModel.workspaceSidebarVisibleWidth = oldWidth
            panel.viewModel.isWorkspaceSidebarExpanded = oldExpanded
            panel.viewModel.workspaceSidebarBrowseMode = oldMode
            panel.organizeCollapseSuppressedUntil = oldOrganizeSuppression
            panel.menuTrackingDepth = oldMenuDepth
            panel.menuTrackingGraceUntil = oldMenuGrace
            panel.commandExpansionLocksCollapse = oldCommandLock
            panel.commandSuppressesHoverExpansion = oldHoverSuppression
            TrayMenuModel.shared.setIfChanged(\.workspaceSidebarDropPreview, oldDropPreview)
            panel.setFrame(oldFrame, display: false)
            shouldSuppressChromeForNativeFullscreenContent = oldSuppression
        }
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.placement = .side
        config.workspaceSidebar.visibility = visibility
        config.workspaceSidebar.collapsedWidth = 28
        config.workspaceSidebar.width = 280
        config.gaps = .zero
        shouldSuppressChromeForNativeFullscreenContent = false
        // Earlier suites may leave menus, drags or command locks behind on the
        // shared panel; hover expansion must start from a quiet panel.
        cancelManipulatedWithMouseState()
        setPinnedDraggedWindowId(nil)
        cancelWorkspaceSidebarSurfaceDrag()
        resetWorkspaceSidebarItemDrag()
        panel.cancelInlineTextEditing()
        panel.endInlineTextEditing()
        panel.projectIconPicker?.close()
        panel.isResizingSidebar = false
        panel.cancelExpansionWork()
        panel.viewModel.workspaceSidebarBrowseMode = .activeProject
        panel.organizeCollapseSuppressedUntil = .distantPast
        panel.menuTrackingDepth = 0
        panel.menuTrackingGraceUntil = .distantPast
        panel.commandExpansionLocksCollapse = false
        panel.commandSuppressesHoverExpansion = false
        TrayMenuModel.shared.setIfChanged(\.workspaceSidebarDropPreview, nil)
        panel.viewModel.setIfChanged(\.workspaceSidebarDropPreview, nil)
        panel.presentsAutoHideForFullscreen = false
        panel.persistentExpansionWidth = nil
        panel.lastNavigationPlacement = nil
        panel.viewModel.isWorkspaceSidebarExpanded = false
        panel.viewModel.workspaceSidebarVisibleWidth = 0
        await body(panel)
    }
}
