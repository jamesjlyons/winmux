@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class WindowTabStripMousePolicyTest: XCTestCase {
    private func makePanel(occlusions: [CGRect]) -> WindowTabStripPanel {
        setUpWorkspacesForTests()
        cancelManipulatedWithMouseState()
        _ = NSApplication.shared
        let panel = WindowTabStripPanel(id: ObjectIdentifier(self))
        let strip = WindowTabStripViewModel(
            id: ObjectIdentifier(self),
            workspaceName: "tabs",
            frame: CGRect(x: 100, y: 900, width: 1000, height: 36),
            groupFrame: CGRect(x: 100, y: 100, width: 1000, height: 836),
            activeWindowId: nil,
            activeWindowCornerRadius: 12,
            tabs: [],
            occludingFloatingWindowFrames: occlusions,
        )
        panel.currentContent = WindowTabGroupChromeContent(strip: strip)
        panel.currentPanelFrame = strip.frame
        return panel
    }

    func testPartialFloatingOverlapKeepsExposedTabsClickable() {
        let panel = makePanel(occlusions: [CGRect(x: 700, y: 100, width: 500, height: 900)])

        panel.updateMousePolicy(at: CGPoint(x: 200, y: 918))
        XCTAssertFalse(panel.ignoresMouseEvents)

        panel.updateMousePolicy(at: CGPoint(x: 800, y: 918))
        XCTAssertTrue(panel.ignoresMouseEvents)

        // Moving back must restore clicks even when the strip model is unchanged.
        panel.updateMousePolicy(at: CGPoint(x: 200, y: 918))
        XCTAssertFalse(panel.ignoresMouseEvents)
    }

    func testFloatingWindowBelowStripDoesNotDisableTabs() {
        let panel = makePanel(occlusions: [CGRect(x: 100, y: 100, width: 1000, height: 800)])
        panel.updateMousePolicy(at: CGPoint(x: 800, y: 918))
        XCTAssertFalse(panel.ignoresMouseEvents)
    }

    func testExternalSuppressionStillDisablesExposedTabs() {
        let panel = makePanel(occlusions: [])
        panel.setExternalIgnoresMouseEvents(true)
        panel.updateMousePolicy(at: CGPoint(x: 200, y: 918))
        XCTAssertTrue(panel.ignoresMouseEvents)

        panel.setExternalIgnoresMouseEvents(false)
        panel.updateMousePolicy(at: CGPoint(x: 200, y: 918))
        XCTAssertFalse(panel.ignoresMouseEvents)
    }

    func testWindowDragSuppressionStillDisablesTabs() {
        let panel = makePanel(occlusions: [])
        defer { cancelManipulatedWithMouseState() }
        XCTAssertTrue(beginWindowMoveWithMouseSessionIfNeeded(
            windowId: 42,
            subject: .window,
            detachOrigin: .window,
            startedInSidebar: false,
            anchorRect: nil,
        ))
        panel.updateMousePolicy(at: CGPoint(x: 200, y: 918))
        XCTAssertTrue(panel.ignoresMouseEvents)

        cancelManipulatedWithMouseState()
        panel.updateMousePolicy(at: CGPoint(x: 200, y: 918))
        XCTAssertFalse(panel.ignoresMouseEvents)
    }

    func testTabDetachKeepsExposedTabsInteractive() {
        let panel = makePanel(occlusions: [])
        defer { cancelManipulatedWithMouseState() }
        XCTAssertTrue(beginWindowMoveWithMouseSessionIfNeeded(
            windowId: 42,
            subject: .window,
            detachOrigin: .tabStrip,
            startedInSidebar: false,
            anchorRect: nil,
        ))
        panel.updateMousePolicy(at: CGPoint(x: 200, y: 918))
        XCTAssertFalse(panel.ignoresMouseEvents)
    }
}
