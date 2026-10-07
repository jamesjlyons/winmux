@testable import AppBundle
import AppKit
import WorkspaceCore
import XCTest

@MainActor final class BrowserToolbarDragTest: XCTestCase {
    func testStandardWindowControlsDispatchTheirWindowActions() throws {
        _ = NSApplication.shared
        let window = BrowserToolbarPanel(surfaceID: .browserTab(profile: UUID(), tab: UUID()))
        let toolbar = window.toolbarView
        window.setFrame(.init(x: 0, y: 0, width: 480, height: 32), display: false)
        defer { window.close() }
        var actions: [BrowserToolbarAction] = []
        window.onAction = { actions.append($0) }
        for identifier in ["close", "minimize", "fullscreen"] {
            let button = try XCTUnwrap(toolbar.windowButtons.first {
                $0.accessibilityIdentifier() == "winmux.browser." + identifier
            })
            XCTAssertFalse(button.superview === toolbar, "Keep the native titlebar hierarchy")
            XCTAssertTrue(button.window === window)
            XCTAssertTrue(button.isEnabled)
            XCTAssertFalse(button.isHidden)
            button.performClick(nil)
        }
        XCTAssertEqual(actions, [.close, .minimize, .fullscreen])
        XCTAssertFalse(window.isMiniaturized, "Traffic lights must act on the page, not its helper header")
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
    }

    func testTrafficLightsAndAddressRemainUsableInNarrowSplits() throws {
        let panel = BrowserToolbarPanel(surfaceID: .browserTab(profile: UUID(), tab: UUID()))
        defer { panel.close() }
        let toolbar = panel.toolbarView
        for width: CGFloat in [164, 170, 200, 239, 240, 279, 280, 379, 380, 700] {
            panel.setFrame(.init(x: 0, y: 0, width: width, height: 32), display: false)
            panel.contentView?.superview?.layoutSubtreeIfNeeded()
            toolbar.needsLayout = true
            toolbar.layoutSubtreeIfNeeded()
            XCTAssertGreaterThanOrEqual(toolbar.address.frame.width, 40, "Address too small at \(width) points")
            for button in toolbar.windowButtons {
                let frame = toolbar.convert(button.bounds, from: button)
                XCTAssertTrue(toolbar.bounds.contains(frame), "Native light clipped at \(width)")
                XCTAssertLessThanOrEqual(frame.maxX, toolbar.address.superview!.frame.minX)
            }
            if let frameView = toolbar.superview {
                let point = toolbar.address.convert(.init(x: toolbar.address.bounds.midX, y: toolbar.address.bounds.midY), to: frameView)
                let hit = frameView.hitTest(point)
                XCTAssertTrue(hit === toolbar.address || hit?.isDescendant(of: toolbar.address.superview!) == true,
                    "Native titlebar must not intercept address entry")
            }
            let controls = toolbar.subviews.filter { !$0.isHidden && !($0 is BrowserChromeBackgroundView) }
            for (index, control) in controls.enumerated() {
                XCTAssertTrue(toolbar.bounds.contains(control.frame), "Control outside \(width)-point header")
                for other in controls.dropFirst(index + 1) {
                    XCTAssertFalse(control.frame.intersects(other.frame), "Controls overlap at \(width) points")
                }
            }
        }
    }

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
        XCTAssertEqual(moved.frame, .init(x: -1433, y: 1150, width: 706, height: 36))
        XCTAssertEqual(page, .init(x: -1433, y: 407, width: 706, height: 779))
        XCTAssertEqual(moved.frame.minY, body.maxY)
        XCTAssertEqual(moved.frame.maxY, page.maxY)
        XCTAssertEqual(moved.url, item.url)
        XCTAssertEqual(moved.surfaceID, item.surfaceID)
        XCTAssertTrue(item.replacingBodyFrame(.zero, screenTop: 900).frame == item.frame)
    }
}
