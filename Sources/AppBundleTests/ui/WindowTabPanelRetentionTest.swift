@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class WindowTabPanelRetentionTest: XCTestCase {
    func testHiddenLiveGroupKeepsItsPanelsAndDeletedGroupReleasesThem() {
        setUpWorkspacesForTests()
        _ = NSApplication.shared
        let controller = WindowTabStripPanelController.shared
        controller.hideAll()
        defer { controller.hideAll() }
        let workspace = Workspace.get(byName: "retained-tabs")
        let group = workspace.rootTilingContainer
        group.layout = .tabGroup
        _ = TestWindow.new(id: 1, parent: group)
        _ = TestWindow.new(id: 2, parent: group)
        let id = ObjectIdentifier(group)
        let visual = controller.visualPanel(for: id)
        let strip = controller.stripPanel(for: id)

        for _ in 0 ..< 10 {
            controller.removeStalePanels(activeIds: [])
            XCTAssertTrue(controller.visualPanel(for: id) === visual)
            XCTAssertTrue(controller.stripPanel(for: id) === strip)
            XCTAssertFalse(visual.isVisible)
            XCTAssertFalse(strip.isVisible)
        }
        controller.refreshHiddenChrome(activeIds: [])
        XCTAssertTrue(controller.visualPanels[id] === visual)
        XCTAssertTrue(controller.stripPanels[id] === strip)

        group.layout = .tiles
        controller.removeStalePanels(activeIds: [])
        XCTAssertNil(controller.visualPanels[id])
        XCTAssertNil(controller.stripPanels[id])
    }

    func testVisualContentTracksLocalOcclusionWithoutDependingOnSelectedTab() {
        setUpWorkspacesForTests()
        let id = ObjectIdentifier(self)
        func strip(active: UInt32, originX: CGFloat, occlusions: [CGRect]) -> WindowTabStripViewModel {
            .init(id: id, workspaceName: "tabs",
                  frame: .init(x: originX, y: 400, width: 600, height: 36),
                  groupFrame: .init(x: originX, y: 0, width: 600, height: 436),
                  activeWindowId: active, activeWindowCornerRadius: 12,
                  tabs: [], occludingFloatingWindowFrames: occlusions)
        }
        let occlusions = [CGRect(x: 400, y: 300, width: 300, height: 300)]
        let first = WindowTabGroupVisualContent(strip: strip(active: 1, originX: 0, occlusions: occlusions))
        XCTAssertEqual(first, WindowTabGroupVisualContent(strip: strip(active: 2, originX: 0, occlusions: occlusions)))
        XCTAssertNotEqual(first, WindowTabGroupVisualContent(strip: strip(active: 1, originX: 100, occlusions: occlusions)),
                          "Moving beneath a stationary floating window must update the frame mask")
    }
}
