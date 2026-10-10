@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class SpaceFocusLifecycleTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        TrayMenuModel.shared.isEnabled = true
        appForTests = TestApp.shared
    }

    func testAutomaticNativeFallbackCannotChangeSpaceEvenOnLaterNotifications() {
        let original = focus.workspace
        let other = createBlankWorkspace(projectId: createWorkspaceProject().id, monitor: mainMonitor)
        let fallback = TestWindow.new(id: 1, parent: other.rootTilingContainer)
        for _ in 0..<3 { updateFocusCache(fallback) }
        XCTAssertTrue(focus.workspace === original)
        XCTAssertTrue(mainMonitor.activeWorkspace === original)

        // Both explicit WinMux navigation and native app-switch intent work.
        XCTAssertTrue(other.focusWorkspace())
        updateFocusCache(fallback)
        XCTAssertTrue(focus.workspace === other)
        XCTAssertTrue(original.focusWorkspace())
        noteNativeSpaceActivationIntent(true)
        updateFocusCache(fallback)
        XCTAssertTrue(focus.workspace === other)
    }

    func testAppSwitchIntentIsConsumedAndClosingInputCancelsIt() {
        let original = focus.workspace
        let first = TestWindow.new(id: 1, parent: original.rootTilingContainer)
        let other = createBlankWorkspace(projectId: createWorkspaceProject().id, monitor: mainMonitor)
        let second = TestWindow.new(id: 2, parent: other.rootTilingContainer)
        noteNativeSpaceActivationIntent(true)
        noteNativeSpaceActivationIntent(false)
        updateFocusCache(second)
        XCTAssertTrue(focus.workspace === original)
        noteNativeSpaceActivationIntent(true)
        updateFocusCache(second)
        XCTAssertTrue(focus.workspace === other)
        updateFocusCache(first)
        XCTAssertTrue(focus.workspace === other)
    }

    func testNativeMinimizeSelectsSameSpaceNeighborBeforeAcceptingMacOSFallback() async throws {
        let original = focus.workspace
        let minimizing = TestWindow.new(id: 1, parent: original.rootTilingContainer)
        let neighbor = TestWindow.new(id: 2, parent: original.rootTilingContainer)
        let other = createBlankWorkspace(projectId: createWorkspaceProject().id, monitor: mainMonitor)
        let fallback = TestWindow.new(id: 3, parent: other.rootTilingContainer)
        XCTAssertTrue(minimizing.focusWindow())
        minimizing.nativeIsMacosMinimized = true
        TestApp.shared.focusedWindow = fallback
        setBlockingRefreshOverridesForTests(refresh: { _ in })

        try await runRefreshSessionBlocking(.ax(kAXWindowMiniaturizedNotification as String), layoutWorkspaces: false)

        XCTAssertTrue(minimizing.parent === macosMinimizedWindowsContainer)
        XCTAssertTrue(focus.workspace === original)
        XCTAssertTrue(focus.windowOrNil === neighbor)
        updateFocusCache(fallback)
        XCTAssertTrue(focus.workspace === original)
    }

    func testMinimizingLastNativeWindowKeepsEmptyCurrentSpace() async throws {
        let original = focus.workspace
        let minimizing = TestWindow.new(id: 1, parent: original.rootTilingContainer)
        let other = createBlankWorkspace(projectId: createWorkspaceProject().id, monitor: mainMonitor)
        let fallback = TestWindow.new(id: 2, parent: other.rootTilingContainer)
        XCTAssertTrue(minimizing.focusWindow())
        minimizing.nativeIsMacosMinimized = true
        TestApp.shared.focusedWindow = fallback
        setBlockingRefreshOverridesForTests(refresh: { _ in })

        try await runRefreshSessionBlocking(.ax(kAXWindowMiniaturizedNotification as String), layoutWorkspaces: false)

        XCTAssertTrue(focus.workspace === original)
        XCTAssertNil(focus.windowOrNil)
        XCTAssertTrue(mainMonitor.activeWorkspace === original)
    }

    func testPruningLastItemOnSecondaryDisplayDoesNotFocusMainDisplaySpace() {
        let main = TestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Main",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 800),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 800), isMain: true)
        let secondary = TestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Secondary",
            rect: Rect(topLeftX: 1000, topLeftY: 0, width: 1000, height: 800),
            visibleRect: Rect(topLeftX: 1000, topLeftY: 0, width: 1000, height: 800), isMain: false)
        setMonitorsForTests([main, secondary])
        let mainWorkspace = focus.workspace
        XCTAssertTrue(main.setActiveWorkspace(mainWorkspace))
        let project = createWorkspaceProject()
        let closing = Workspace.get(byName: "Closing view")
        closing.assignProject(project.id)
        closing.seedMonitorIfNeeded(secondary)
        let window = TestWindow.new(id: 1, parent: closing.rootTilingContainer)
        XCTAssertTrue(closing.focusWorkspace())
        window.unbindFromParent()

        Workspace.reconcileWorkspaceState()

        XCTAssertEqual(focus.workspace.projectId, project.id)
        XCTAssertEqual(MonitorViewportId(focus.workspace.workspaceMonitor), MonitorViewportId(secondary))
        XCTAssertTrue(main.activeWorkspace === mainWorkspace)
        XCTAssertTrue(focus.workspace.isEffectivelyEmpty)
    }
}
