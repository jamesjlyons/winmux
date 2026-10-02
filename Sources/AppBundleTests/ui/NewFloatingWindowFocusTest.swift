@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class NewFloatingWindowFocusTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        TrayMenuModel.shared.isEnabled = true
        appForTests = TestApp.shared
    }

    func testNewFloatingWindowIsFocusedAndRaisedAfterPlacement() async throws {
        let workspace = focus.workspace
        let tiled = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        XCTAssertTrue(tiled.focusWindow())
        TestApp.shared.focusedWindow = tiled
        let floating = FloatingFocusTestWindow(id: 2, parent: workspace)
        floating.onFocus = { XCTAssertGreaterThan(tiled.frameWriteCount, 0) }
        setBlockingRefreshOverridesForTests(refresh: { _ in noteNewFloatingWindow(floating) })
        defer { setBlockingRefreshOverridesForTests() }

        try await runRefreshSessionBlocking(.ax(kAXWindowCreatedNotification as String))

        XCTAssertTrue(focus.windowOrNil === floating)
        XCTAssertTrue(TestApp.shared.focusedWindow === floating)
        XCTAssertEqual(floating.focusRequests, 1)
        XCTAssertTrue(floating.parent === workspace)
    }

    func testAlreadyNativeFocusedFloatingWindowStillGetsRaisedOnce() async throws {
        let floating = FloatingFocusTestWindow(id: 1, parent: focus.workspace)
        XCTAssertTrue(floating.focusWindow())
        TestApp.shared.focusedWindow = floating
        noteNewFloatingWindow(floating)
        setBlockingRefreshOverridesForTests(refresh: { _ in })
        defer { setBlockingRefreshOverridesForTests() }

        try await runRefreshSessionBlocking(.ax(kAXWindowCreatedNotification as String))
        try await runRefreshSessionBlocking(.ax(kAXFocusedWindowChangedNotification as String))

        XCTAssertEqual(floating.focusRequests, 1)
    }

    func testStartupWindowsDoNotTakeFocus() {
        let floating = FloatingFocusTestWindow(id: 1, parent: focus.workspace)
        $_isStartup.withValue(true) { noteNewFloatingWindow(floating) }
        XCTAssertFalse(focusNewFloatingWindowAfterLayout())
        XCTAssertEqual(floating.focusRequests, 0)
    }

    func testWindowRoutedToHiddenWorkspaceDoesNotSwitchWorkspaces() {
        let workspace = focus.workspace
        let floating = FloatingFocusTestWindow(id: 1, parent: workspace)
        noteNewFloatingWindow(floating)
        floating.bindAsFloatingWindow(to: Workspace.get(byName: "background"))

        XCTAssertFalse(focusNewFloatingWindowAfterLayout())
        XCTAssertTrue(focus.workspace === workspace)
        XCTAssertEqual(floating.focusRequests, 0)
    }

    func testRetiledOrClosedWindowDoesNotTakeFocus() {
        let workspace = focus.workspace
        let tiled = FloatingFocusTestWindow(id: 1, parent: workspace)
        let closed = FloatingFocusTestWindow(id: 2, parent: workspace)
        noteNewFloatingWindow(tiled)
        noteNewFloatingWindow(closed)
        tiled.bind(to: workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        closed.unbindFromParent()

        XCTAssertFalse(focusNewFloatingWindowAfterLayout())
        XCTAssertEqual(tiled.focusRequests + closed.focusRequests, 0)
    }

    func testMinimizedWindowIsNormalizedBeforeSelectingNewFloat() async throws {
        let workspace = focus.workspace
        let tiled = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        XCTAssertTrue(tiled.focusWindow())
        TestApp.shared.focusedWindow = tiled
        let minimized = TestWindow.new(id: 2, parent: workspace)
        minimized.nativeIsMacosMinimized = true
        setBlockingRefreshOverridesForTests(refresh: { _ in noteNewFloatingWindow(minimized) })
        defer { setBlockingRefreshOverridesForTests() }

        try await runRefreshSessionBlocking(.ax(kAXWindowCreatedNotification as String))

        XCTAssertTrue(minimized.parent === macosMinimizedWindowsContainer)
        XCTAssertTrue(focus.windowOrNil === tiled)
        XCTAssertTrue(TestApp.shared.focusedWindow === tiled)
    }

    func testLatestOpeningWinsAndIsNotRaisedAgain() {
        let first = FloatingFocusTestWindow(id: 1, parent: focus.workspace)
        let latest = FloatingFocusTestWindow(id: 2, parent: focus.workspace)
        noteNewFloatingWindow(first)
        noteNewFloatingWindow(latest)

        XCTAssertTrue(focusNewFloatingWindowAfterLayout())
        XCTAssertEqual(first.focusRequests, 0)
        XCTAssertEqual(latest.focusRequests, 1)
        XCTAssertFalse(focusNewFloatingWindowAfterLayout())
    }

    func testFloatingFocusAlwaysUsesExplicitRaise() {
        for count in [1, 2] {
            for previous: UInt32? in [nil, 1, 2] {
                XCTAssertFalse(shouldUseActivationOnlyForNativeFocus(
                    targetWindowId: 1,
                    lastNativeFocusedWindowId: previous,
                    logicalWindowsCount: count,
                    isFloating: true,
                ))
            }
        }
        XCTAssertTrue(shouldUseActivationOnlyForNativeFocus(
            targetWindowId: 1,
            lastNativeFocusedWindowId: 1,
            logicalWindowsCount: 2,
            isFloating: false,
        ))
    }
}

private final class FloatingFocusTestWindow: Window {
    var focusRequests = 0
    var onFocus: (@MainActor () -> Void)?

    @MainActor init(id: UInt32, parent: Workspace) {
        super.init(id: id, TestApp.shared, lastFloatingSize: nil, parent: parent, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        TestApp.shared._windows.append(self)
        recordAuthoritativeActualRect(Rect(topLeftX: 100, topLeftY: 100, width: 300, height: 200))
    }

    override var title: String { get async { "Floating focus test" } }
    override var isHiddenInCorner: Bool { false }
    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {}
    @MainActor override func getAxRect() async throws -> Rect? { lastKnownActualRect }
    @MainActor override func nativeFocus() {
        focusRequests += 1
        onFocus?()
        TestApp.shared.focusedWindow = self
    }
}
