@testable import AppBundle
import AppKit
import XCTest

@MainActor final class BrowserAccessibilityWindowsTest: XCTestCase {
    func testBrowserWindowsMergeWithoutLosingOrDuplicatingAppKitWindows() {
        _ = NSApplication.shared
        let settings = fixtureWindow(visible: true)
        let browser = fixtureWindow(visible: true)
        defer { settings.close(); browser.close() }
        let first = browserAccessibilityWindows(inherited: [settings], toolbarWindows: [browser])
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue((first[0] as? NSWindow) === settings)
        XCTAssertTrue((first[1] as? NSWindow) === browser)
        let repeated = browserAccessibilityWindows(inherited: first, toolbarWindows: [browser])
        XCTAssertEqual(repeated.count, 2)
    }

    func testFreshQueryExcludesHiddenAndDecorativePanelsAndReflectsVisibilityChanges() {
        _ = NSApplication.shared
        let header = fixtureWindow(visible: false)
        let decorative = fixtureWindow(visible: true)
        decorative.setAccessibilityElement(false)
        defer { header.close(); decorative.close() }
        XCTAssertTrue(browserAccessibilityWindows(inherited: nil, toolbarWindows: [header, decorative]).isEmpty)
        header.reportedVisible = true
        XCTAssertEqual(browserAccessibilityWindows(inherited: nil, toolbarWindows: [header, decorative]).count, 1)
        header.reportedVisible = false
        XCTAssertTrue(browserAccessibilityWindows(inherited: nil, toolbarWindows: [header, decorative]).isEmpty)
    }

    private func fixtureWindow(visible: Bool) -> BrowserAccessibilityFixtureWindow {
        let window = BrowserAccessibilityFixtureWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setAccessibilityElement(true)
        window.reportedVisible = visible
        return window
    }
}

/// Simulate visibility without ordering windows or replacing the test's NSApp.
@MainActor private final class BrowserAccessibilityFixtureWindow: NSWindow {
    var reportedVisible = false
    override var isVisible: Bool { reportedVisible }
}
