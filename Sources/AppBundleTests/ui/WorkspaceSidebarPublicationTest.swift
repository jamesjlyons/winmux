@testable import AppBundle
import Combine
import XCTest

@MainActor
final class WorkspaceSidebarPublicationTest: XCTestCase {
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
