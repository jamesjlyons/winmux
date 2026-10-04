@testable import AppBundle
import Combine
import XCTest

@MainActor
final class WorkspaceSidebarPublicationTest: XCTestCase {
    func testRefreshingExpandedSidebarDoesNotPublishUnchangedExpansion() {
        setUpWorkspacesForTests()
        let panel = WorkspaceSidebarPanel.shared
        let oldConfig = config.workspaceSidebar
        let oldEnabled = TrayMenuModel.shared.isEnabled
        defer {
            config.workspaceSidebar = oldConfig
            TrayMenuModel.shared.isEnabled = oldEnabled
            panel.resetHiddenSidebarState()
        }
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.alwaysExpanded = true
        TrayMenuModel.shared.isEnabled = true
        panel.refresh(on: mainMonitor)
        XCTAssertTrue(panel.viewModel.isWorkspaceSidebarExpanded)
        var publications = 0
        let subscription = panel.viewModel.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }

        panel.refresh(on: mainMonitor)

        XCTAssertEqual(publications, 0, "Focus/title refreshes must not invalidate the sidebar's entire SwiftUI tree")
    }

    func testUnrelatedMenuChangeDoesNotInvalidateSidebarAndLocalStateSurvivesSync() {
        setUpWorkspacesForTests()
        let shared = TrayMenuModel.shared
        let panel = WorkspaceSidebarPanel.shared
        let oldTrayText = shared.trayText
        let oldPadding = shared.workspaceSidebarTopPadding
        let oldWidth = panel.viewModel.workspaceSidebarVisibleWidth
        let oldExpanded = panel.viewModel.isWorkspaceSidebarExpanded
        defer {
            shared.trayText = oldTrayText
            shared.workspaceSidebarTopPadding = oldPadding
            panel.viewModel.workspaceSidebarVisibleWidth = oldWidth
            panel.viewModel.isWorkspaceSidebarExpanded = oldExpanded
        }
        panel.viewModel.workspaceSidebarVisibleWidth = 145
        panel.viewModel.isWorkspaceSidebarExpanded = true
        panel.syncModelFromShared()
        var publications = 0
        let subscription = panel.viewModel.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }

        shared.trayText = "unrelated-mode-change"
        panel.syncModelFromShared()
        XCTAssertEqual(publications, 0)
        shared.workspaceSidebarTopPadding = oldPadding + 1
        panel.syncModelFromShared()
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 145)
        XCTAssertTrue(panel.viewModel.isWorkspaceSidebarExpanded)
    }
}
