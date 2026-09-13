@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class WorkspaceSidebarWidthTest: XCTestCase {
    func testResizeClampsToUsableWidthsAndDisplay() {
        XCTAssertEqual(clampedWorkspaceSidebarWidth(50, collapsedWidth: 40, availableWidth: 1512), 120)
        XCTAssertEqual(clampedWorkspaceSidebarWidth(900, collapsedWidth: 40, availableWidth: 1512), 480)
        XCTAssertEqual(clampedWorkspaceSidebarWidth(400, collapsedWidth: 40, availableWidth: 300), 300)
        XCTAssertEqual(clampedWorkspaceSidebarWidth(120, collapsedWidth: 120, availableWidth: 700), 121)
        XCTAssertEqual(clampedWorkspaceSidebarWidth(.nan, collapsedWidth: 40, availableWidth: 1512), 120)
    }

    func testWidthEditPreservesCommentAndUnrelatedSettings() {
        let input = """
        start-at-login = true
        [workspace-sidebar]
            width = 240 # preferred size
            collapsed-width = 40
        [workspace-sidebar.workspace-labels]
            code = 'Design'
        """
        let updated = updateWorkspaceSidebarWidthConfig(in: input, width: 140)
        XCTAssertEqual(updated, input.replacingOccurrences(of: "width = 240", with: "width = 140"))
        let parsed = parseConfig(updated)
        XCTAssertTrue(parsed.errors.isEmpty)
        XCTAssertEqual(parsed.config.workspaceSidebar.width, 140)
    }

    func testDottedWidthIsUpdatedWithoutDuplicateTable() {
        let input = "workspace-sidebar.width = 240 # keep\nworkspace-sidebar.enabled = true\n"
        let updated = updateWorkspaceSidebarWidthConfig(in: input, width: 180)
        XCTAssertEqual(updated, input.replacingOccurrences(of: "240", with: "180"))
        XCTAssertTrue(parseConfig(updated).errors.isEmpty)
    }

    func testMissingWidthIsInsertedInSidebarTable() {
        let updated = updateWorkspaceSidebarWidthConfig(in: "[workspace-sidebar]\nenabled = true\n", width: 120)
        let parsed = parseConfig(updated)
        XCTAssertTrue(parsed.errors.isEmpty)
        XCTAssertEqual(parsed.config.workspaceSidebar.width, 120)
        XCTAssertTrue(parsed.config.workspaceSidebar.enabled)
    }

    func testDensityUsesSectionWidthAfterInsets() {
        XCTAssertEqual(WorkspaceSidebarDensity(sectionWidth: 240 - 24), .full)
        XCTAssertEqual(WorkspaceSidebarDensity(sectionWidth: 180 - 24), .narrow)
        XCTAssertEqual(WorkspaceSidebarDensity(sectionWidth: 140 - 24), .narrow)
        XCTAssertEqual(WorkspaceSidebarDensity(sectionWidth: 120 - 24), .minimal)
    }
}
