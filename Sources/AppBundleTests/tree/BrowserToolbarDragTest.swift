@testable import AppBundle
import AppKit
import WorkspaceCore
import XCTest

@MainActor final class BrowserToolbarDragTest: XCTestCase {
    func testInteractiveHeaderHasWindowAndToolbarAccessibilityWhileBackingIsIgnored() throws {
        _ = NSApplication.shared
        let id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let panel = BrowserToolbarPanel(surfaceID: id)
        defer { panel.close() }
        let backing = try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue == "winmux-browser-page-chrome-" + id.description
        })
        defer { backing.close() }
        XCTAssertTrue(panel.isAccessibilityElement())
        XCTAssertEqual(panel.accessibilityRole(), .window)
        XCTAssertEqual(panel.accessibilitySubrole(), .standardWindow)
        XCTAssertEqual(panel.accessibilityTitle(), "Web page controls")
        XCTAssertEqual(panel.accessibilityIdentifier(), "winmux.browser.controls." + id.description)
        XCTAssertTrue(panel.accessibilityChildren()?.contains { ($0 as? NSView) === panel.toolbarView } == true)
        XCTAssertTrue(panel.toolbarView.isAccessibilityElement())
        XCTAssertEqual(panel.toolbarView.accessibilityRole(), .toolbar)
        XCTAssertFalse(backing.isAccessibilityElement())
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.isVisible, "Accessibility registration must not show or activate the panel")
    }

    func testSmallPointerMotionRemainsClickAndFirstDragKeepsOriginalAnchor() {
        var gesture = BrowserToolbarDragGesture()
        gesture.begin(at: .init(x: -200, y: 35))
        XCTAssertTrue(gesture.update(at: .init(x: -198, y: 37)).isEmpty)
        XCTAssertEqual(gesture.update(at: .init(x: -196, y: 35)), [
            .init(phase: .began, point: .init(x: -200, y: 35)),
            .init(phase: .changed, point: .init(x: -196, y: 35)),
        ])
        XCTAssertEqual(gesture.update(at: .init(x: -190, y: 42)), [
            .init(phase: .changed, point: .init(x: -190, y: 42)),
        ])
        XCTAssertTrue(gesture.end())
    }

    func testCancelledOrReleasedGestureCannotRestartFromStrayEvents() {
        var gesture = BrowserToolbarDragGesture()
        gesture.begin(at: .zero)
        XCTAssertTrue(gesture.update(at: .init(x: 2, y: 1)).isEmpty)
        XCTAssertFalse(gesture.end(), "A short click must still focus the page")
        XCTAssertTrue(gesture.update(at: .init(x: 200, y: 100)).isEmpty)
        gesture.begin(at: .zero)
        XCTAssertEqual(gesture.update(at: .init(x: 20, y: 0)).count, 2)
        XCTAssertTrue(gesture.end(), "Cancellation retires the drag exactly once")
        XCTAssertFalse(gesture.end())
        XCTAssertTrue(gesture.update(at: .init(x: 300, y: 100)).isEmpty)
    }

    func testMovedAndResizedBodyKeepsContinuousChromeAcrossDisplays() throws {
        let geometry = try XCTUnwrap(BrowserPageChromeGeometry(frame: .init(x: 100, y: 120, width: 640, height: 500)))
        let item = BrowserToolbarItem(
            surfaceID: .browserTab(profile: UUID(), tab: UUID()),
            frame: BrowserPageChromeGeometry.appKitRect(geometry.headerFrame, screenTop: 900),
            url: "https://example.com", canGoBack: true, canGoForward: false, isLoading: false, isFocused: true,
            pageFrame: BrowserPageChromeGeometry.appKitRect(geometry.pageFrame, screenTop: 900),
            bodyFrame: BrowserPageChromeGeometry.appKitRect(geometry.bodyFrame, screenTop: 900))
        let moved = item.replacingBodyFrame(.init(x: -1432, y: -250, width: 704, height: 742), screenTop: 900)
        let body = try XCTUnwrap(moved.bodyFrame), page = try XCTUnwrap(moved.pageFrame)
        XCTAssertEqual(body, .init(x: -1432, y: 408, width: 704, height: 742))
        XCTAssertEqual(moved.frame, .init(x: -1434, y: 1150, width: 708, height: 44))
        XCTAssertEqual(page, .init(x: -1434, y: 406, width: 708, height: 788))
        XCTAssertEqual(moved.frame.minY, body.maxY)
        XCTAssertEqual(moved.frame.maxY, page.maxY)
        XCTAssertEqual(moved.url, item.url)
        XCTAssertEqual(moved.surfaceID, item.surfaceID)
        XCTAssertTrue(item.replacingBodyFrame(.zero, screenTop: 900).frame == item.frame)
    }
}
