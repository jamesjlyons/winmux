@testable import AppBundle
import AppKit
import Common
import XCTest

final class RefreshFocusSyncTest: XCTestCase {
    @MainActor
    func testRegularAppWithoutAccessibleFocusKeepsForeground() async throws {
        setUpWorkspacesForTests()
        TrayMenuModel.shared.isEnabled = true
        let previous = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        XCTAssertTrue(previous.focusWindow())
        TestApp.shared.focusedWindow = previous
        updateFocusCache(previous)
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = nil
        setBlockingRefreshOverridesForTests(refresh: { _ in })
        defer {
            appForTests = nil
            setBlockingRefreshOverridesForTests()
        }

        for event in [RefreshSessionEvent.globalObserver(NSWorkspace.didActivateApplicationNotification.rawValue),
                      .ax(kAXFocusedWindowChangedNotification as String), .globalObserverLeftMouseUp] {
            try await runRefreshSessionBlocking(event)
            XCTAssertNil(TestApp.shared.focusedWindow, "Refresh must not reactivate the previous app")
            XCTAssertTrue(focus.windowOrNil === previous, "Keep the workspace selection for explicit navigation")
        }
    }

    @MainActor
    func testMissingAccessibleFocusRequiresAnActualSelectionChange() {
        XCTAssertFalse(shouldSyncFocusBackToMacOs(nativeFocused: nil, frontmostActivationPolicy: .regular))
        XCTAssertFalse(shouldSyncFocusBackToMacOs(nativeFocused: nil, frontmostActivationPolicy: nil))
        XCTAssertTrue(shouldSyncFocusBackToMacOs(
            nativeFocused: nil, frontmostActivationPolicy: .regular, logicalFocusChanged: true))
        XCTAssertFalse(shouldSyncFocusBackToMacOs(
            nativeFocused: nil, frontmostActivationPolicy: .accessory, logicalFocusChanged: true))
    }

    @MainActor
    func testClosingTheSelectedWindowStillFocusesItsReplacement() async throws {
        setUpWorkspacesForTests()
        TrayMenuModel.shared.isEnabled = true
        let replacement = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let closed = TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        XCTAssertTrue(closed.focusWindow())
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = nil
        setBlockingRefreshOverridesForTests(refresh: { _ in
            closed.unbindFromParent()
            TestApp.shared._windows.removeAll { $0 === closed }
        })
        defer {
            appForTests = nil
            setBlockingRefreshOverridesForTests()
        }

        try await runRefreshSessionBlocking(.ax(kAXUIElementDestroyedNotification as String))

        XCTAssertTrue(focus.windowOrNil === replacement)
        XCTAssertTrue(TestApp.shared.focusedWindow === replacement)
    }

    @MainActor
    func testShouldNotSyncFocusBackToPopupWindow() {
        setUpWorkspacesForTests()

        let popup = TestWindow.new(id: 1, parent: macosPopupWindowsContainer)

        XCTAssertFalse(shouldSyncFocusBackToMacOs(nativeFocused: popup, frontmostActivationPolicy: .accessory))
    }

    @MainActor
    func testShouldNotSyncFocusBackToAccessoryAppWithoutFocusedWindow() {
        XCTAssertFalse(shouldSyncFocusBackToMacOs(nativeFocused: nil, frontmostActivationPolicy: .accessory))
    }

    @MainActor
    func testBrowserForegroundDoesNotRefocusTheOldNativeLeaf() {
        XCTAssertFalse(shouldSyncFocusBackToMacOs(nativeFocused: nil, frontmostActivationPolicy: .regular, browserOwnsForeground: true))
    }

    @MainActor
    func testShouldSyncFocusBackToRegularWorkspaceWindow() {
        setUpWorkspacesForTests()

        let window = TestWindow.new(id: 1, parent: focus.workspace)

        XCTAssertTrue(shouldSyncFocusBackToMacOs(nativeFocused: window, frontmostActivationPolicy: .regular))
    }
}
