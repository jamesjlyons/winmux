@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class WorkspaceSidebarGapTest: XCTestCase {
    func testGapSettingsPersistWithoutChangingOtherSidebarSettings() {
        XCTAssertEqual(WorkspaceSidebarConfig().topGap, 0)
        XCTAssertEqual(WorkspaceSidebarConfig().bottomGap, 0)
        XCTAssertEqual(WorkspaceSidebarConfig().edgeGap, 0)
        var text = "[workspace-sidebar]\nwidth = 280\nmenu-bar-reserve-height = 28\n"
        for gap in [12, 0, 120] {
            for key in ["top-gap", "bottom-gap", "edge-gap"] {
                text = updateSettingsScalarConfig(in: text, section: "workspace-sidebar", key: key, renderedValue: "\(gap)")
            }
            let parsed = parseConfig(text)
            XCTAssertTrue(parsed.errors.isEmpty, parsed.errors.description)
            XCTAssertEqual(parsed.config.workspaceSidebar.topGap, gap)
            XCTAssertEqual(parsed.config.workspaceSidebar.bottomGap, gap)
            XCTAssertEqual(parsed.config.workspaceSidebar.edgeGap, gap)
            XCTAssertEqual(parsed.config.workspaceSidebar.menuBarReserveHeight, 28)
            XCTAssertEqual(parsed.config.workspaceSidebar.width, 280)
        }
        for key in ["top-gap", "bottom-gap", "edge-gap"] {
            for invalid in ["-1", "1.5", "'12'", "true"] {
                XCTAssertFalse(parseConfig("[workspace-sidebar]\n\(key) = \(invalid)").errors.isEmpty)
            }
        }
    }

    func testGapsPositionPanelOnEachMonitorBelowMenuBarReserve() {
        var config = WorkspaceSidebarConfig()
        config.topGap = 12
        config.edgeGap = 8
        for origin in [CGPoint.zero, CGPoint(x: -1920, y: 200), CGPoint(x: 1512, y: -400)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 1512, height: 982))
            for bottomGap in [0, 20] {
                config.bottomGap = bottomGap
                let frame = workspaceSidebarPanelFrame(screenFrame: screen, width: 240, configuration: config)
                XCTAssertEqual(frame.minX, screen.minX + 8)
                XCTAssertEqual(frame.maxY, screen.maxY - 40)
                XCTAssertEqual(frame.minY, screen.minY + CGFloat(bottomGap))
                XCTAssertEqual(frame.width, 240)
                XCTAssertEqual(frame.height, screen.height - 40 - CGFloat(bottomGap))
            }
        }
    }

    func testLargeGapsAndOrganizeWidthStayInsideDisplay() {
        var config = WorkspaceSidebarConfig()
        config.topGap = Int.max
        config.bottomGap = Int.max
        config.edgeGap = Int.max
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let frame = workspaceSidebarPanelFrame(screenFrame: screen, width: 2000, configuration: config)
        XCTAssertEqual(frame, CGRect(x: 560, y: 0, width: 240, height: 1))
        config.topGap = 12
        let bottomClampedFrame = workspaceSidebarPanelFrame(screenFrame: screen, width: 2000, configuration: config)
        XCTAssertEqual(bottomClampedFrame, CGRect(x: 560, y: 559, width: 240, height: 1))
    }

    func testReservedSpaceIncludesEdgeGapExceptWhenHiddenOrFullscreen() {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.edgeGap = 12
        config.workspaceSidebar.topGap = 16
        config.workspaceSidebar.bottomGap = 20
        for visibility in WorkspaceSidebarVisibility.allCases {
            config.workspaceSidebar.visibility = visibility
            let expected: CGFloat = visibility == .autoHide ? 0 : workspaceSidebarRestingWidth(config.workspaceSidebar) + 12
            XCTAssertEqual(mainMonitor.workspaceSidebarInset, expected)
        }
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        window.isFullscreen = true
        XCTAssertEqual(mainMonitor.workspaceSidebarInset, 0)
    }

    func testFloatingSidebarRoundsLeftCornersToMatchRightCorners() {
        let rect = CGRect(x: 0, y: 0, width: 240, height: 600)
        let flush = WorkspaceSidebarPanelShape(rightCornerRadius: 16).path(in: rect)
        let floating = WorkspaceSidebarPanelShape(rightCornerRadius: 16, leftCornerRadius: 16).path(in: rect)
        for y: CGFloat in [1, 599] {
            XCTAssertTrue(flush.contains(CGPoint(x: 1, y: y)))
            XCTAssertFalse(floating.contains(CGPoint(x: 1, y: y)))
            XCTAssertFalse(floating.contains(CGPoint(x: 239, y: y)))
        }
        XCTAssertTrue(floating.contains(CGPoint(x: 1, y: 300)))
        XCTAssertTrue(floating.contains(CGPoint(x: 239, y: 300)))
    }
}
