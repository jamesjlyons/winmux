import AppKit
import Combine
@testable import AppBundle
import XCTest

@MainActor
final class WorkspaceSidebarTransitionTest: XCTestCase {
    func testRepeatedExpansionRequestsDoNotPublishOrRestartTransition() async {
        await withSidebar { panel in
            var publications = 0
            var expansions = 0
            let subscription = panel.viewModel.objectWillChange.sink { publications += 1 }
            let observer = NotificationCenter.default.addObserver(
                forName: workspaceSidebarWillExpandNotification, object: panel, queue: .main
            ) { _ in expansions += 1 }
            defer {
                subscription.cancel()
                NotificationCenter.default.removeObserver(observer)
            }
            for _ in 0 ..< 100 { panel.expandSidebar(to: 280) }
            print("SIDEBAR_TRANSITION_BENCHMARK requests=100 publications=\(publications) expansionNotifications=\(expansions)")
            XCTAssertEqual(publications, 0)
            XCTAssertEqual(expansions, 0)
        }
    }

    func testPendingExitKeepsContentAndItsOriginalDeadline() async {
        await withSidebar { panel in
            var collapses = 0
            let observer = NotificationCenter.default.addObserver(
                forName: workspaceSidebarWillCollapseNotification, object: panel, queue: .main
            ) { _ in collapses += 1 }
            defer { NotificationCenter.default.removeObserver(observer) }
            panel.handleHoverExit(collapsedWidth: 28)
            let pending = panel.pendingCollapse
            for _ in 0 ..< 50 { panel.handleHoverExit(collapsedWidth: 28) }
            XCTAssertNotNil(pending)
            XCTAssertTrue(panel.pendingCollapse === pending)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 280)
            XCTAssertEqual(collapses, 0)
        }
    }

    func testPointerMovementDuringCloseDoesNotScheduleAnotherCollapse() async {
        await withSidebar { panel in
            panel.viewModel.workspaceSidebarVisibleWidth = 28
            panel.scheduleCollapseFinalize()
            let finalize = panel.pendingCollapseFinalize
            for _ in 0 ..< 50 { panel.handleHoverExit(collapsedWidth: 28) }
            XCTAssertNil(panel.pendingCollapse)
            XCTAssertTrue(panel.pendingCollapseFinalize === finalize)
        }
    }

    func testReentryCancelsExitWithoutAnotherExpansion() async {
        await withSidebar { panel in
            panel.scheduleCollapse(collapsedWidth: 28)
            let pending = panel.pendingCollapse
            var publications = 0
            let subscription = panel.viewModel.objectWillChange.sink { publications += 1 }
            defer { subscription.cancel() }
            panel.handleHoverEnter(expandedWidth: 280, collapsedWidth: 28)
            XCTAssertTrue(pending?.isCancelled == true)
            XCTAssertNil(panel.pendingCollapse)
            XCTAssertEqual(publications, 0)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 280)
        }
    }

    func testReentryDuringCloseCancelsFinalizationAndRestoresWidth() async {
        await withSidebar { panel in
            panel.viewModel.workspaceSidebarVisibleWidth = 28
            panel.scheduleCollapseFinalize()
            let finalize = panel.pendingCollapseFinalize
            panel.expandSidebar(to: 280)
            XCTAssertTrue(finalize?.isCancelled == true)
            XCTAssertNil(panel.pendingCollapseFinalize)
            XCTAssertTrue(panel.viewModel.isWorkspaceSidebarExpanded)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 280)
        }
    }

    func testHoverCollapseReachesRestingState() async {
        await withSidebar { panel in
            let start = ContinuousClock.now
            panel.handleHoverExit(collapsedWidth: 28)
            while panel.viewModel.isWorkspaceSidebarExpanded, start.duration(to: .now) < .seconds(2) {
                try? await Task.sleep(for: .milliseconds(10))
            }
            print("SIDEBAR_CLOSE_BENCHMARK elapsed=\(start.duration(to: .now))")
            XCTAssertFalse(panel.viewModel.isWorkspaceSidebarExpanded)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 28)
            XCTAssertNil(panel.pendingCollapse)
            XCTAssertNil(panel.pendingCollapseFinalize)
        }
    }

    func testExpansionBookkeepingDoesNotInvalidateRenderedSnapshot() async {
        await withSidebar { panel in
            var publications = 0
            let subscription = panel.viewModel.objectWillChange.sink { publications += 1 }
            defer { subscription.cancel() }
            let before = workspaceSidebarSnapshot(from: panel.viewModel)
            panel.viewModel.isWorkspaceSidebarExpanded = false
            XCTAssertEqual(workspaceSidebarSnapshot(from: panel.viewModel), before)
            XCTAssertEqual(publications, 0)
            panel.viewModel.isWorkspaceSidebarExpanded = true
        }
    }

    func testMenuAndEditorLocksPreventHoverCollapse() async {
        await withSidebar { panel in
            panel.menuTrackingDepth = 1
            panel.handleHoverExit(collapsedWidth: 28)
            XCTAssertNil(panel.pendingCollapse)
            panel.menuTrackingDepth = 0
            panel.menuTrackingGraceUntil = .now.addingTimeInterval(1)
            panel.handleHoverExit(collapsedWidth: 28)
            XCTAssertNil(panel.pendingCollapse)
            panel.menuTrackingGraceUntil = .distantPast
            panel.commandExpansionLocksCollapse = true
            panel.handleHoverExit(collapsedWidth: 28)
            XCTAssertNil(panel.pendingCollapse)
            panel.commandExpansionLocksCollapse = false
            panel.handleHoverExit(collapsedWidth: 28)
            XCTAssertNotNil(panel.pendingCollapse)
        }
    }

    private func withSidebar(_ body: @MainActor (WorkspaceSidebarPanel) async -> Void) async {
        setUpWorkspacesForTests()
        let panel = WorkspaceSidebarPanel.shared
        let oldConfig = config
        let oldFrame = panel.frame
        let oldWidth = panel.viewModel.workspaceSidebarVisibleWidth
        let oldExpanded = panel.viewModel.isWorkspaceSidebarExpanded
        let oldPendingRecheck = panel.hasPendingHoverRecheck
        let oldMode = panel.viewModel.workspaceSidebarBrowseMode
        let oldSuppression = panel.organizeCollapseSuppressedUntil
        let oldMenuDepth = panel.menuTrackingDepth
        let oldMenuGrace = panel.menuTrackingGraceUntil
        let oldCommandLock = panel.commandExpansionLocksCollapse
        let wasVisible = panel.isVisible
        defer {
            panel.cancelExpansionWork()
            panel.orderOut(nil)
            config = oldConfig
            panel.viewModel.workspaceSidebarVisibleWidth = oldWidth
            panel.viewModel.isWorkspaceSidebarExpanded = oldExpanded
            panel.hasPendingHoverRecheck = oldPendingRecheck
            panel.viewModel.workspaceSidebarBrowseMode = oldMode
            panel.organizeCollapseSuppressedUntil = oldSuppression
            panel.menuTrackingDepth = oldMenuDepth
            panel.menuTrackingGraceUntil = oldMenuGrace
            panel.commandExpansionLocksCollapse = oldCommandLock
            panel.setFrame(oldFrame, display: false)
            if wasVisible { panel.orderFront(nil) }
        }
        config.workspaceSidebar.alwaysExpanded = false
        config.workspaceSidebar.width = 280
        config.workspaceSidebar.collapsedWidth = 28
        config.workspaceSidebar.autoHide = false
        panel.cancelExpansionWork()
        panel.hasPendingHoverRecheck = true
        panel.viewModel.workspaceSidebarBrowseMode = .activeProject
        panel.organizeCollapseSuppressedUntil = .distantPast
        panel.menuTrackingDepth = 0
        panel.menuTrackingGraceUntil = .distantPast
        panel.commandExpansionLocksCollapse = false
        panel.viewModel.isWorkspaceSidebarExpanded = true
        panel.viewModel.workspaceSidebarVisibleWidth = 280
        panel.setFrame(CGRect(x: -10000, y: -10000, width: 280, height: 600), display: false)
        panel.orderFront(nil)
        await body(panel)
    }
}
