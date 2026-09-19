@testable import AppBundle
import AppKit
import Common
import XCTest

final class GeometryRefreshTest: XCTestCase {
    private let moved = RefreshSessionEvent.ax(kAXMovedNotification as String)
    private let resized = RefreshSessionEvent.ax(kAXResizedNotification as String)

    @MainActor
    func testGeometrySkipsDiscoveryAndPreservesUnrelatedFramesAndNativeState() async throws {
        setUpWorkspacesForTests()
        TrayMenuModel.shared.isEnabled = true
        config.workspaceSidebar.enabled = false
        config.windowTabs.enabled = false
        appForTests = TestApp.shared
        let first = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let second = TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        TestApp.shared.focusedWindow = first
        try await focus.workspace.layoutWorkspace()
        let expected = first.lastAppliedLayoutPhysicalRect
        first.setAxFrame(CGPoint(x: 50, y: 50), nil)
        first.invalidateLastKnownNativeState()
        second.invalidateLastKnownNativeState()
        let firstWrites = first.frameWriteCount
        let secondWrites = second.frameWriteCount
        setBlockingRefreshOverridesForTests(refresh: { _ in XCTFail("Geometry must not enumerate apps") })
        defer { setBlockingRefreshOverridesForTests() }

        try await runRefreshSessionBlocking(moved, scope: .geometry(first))

        XCTAssertEqual(first.frameWriteCount, firstWrites + 1)
        XCTAssertEqual(second.frameWriteCount, secondWrites)
        XCTAssertEqual(first.lastAppliedLayoutPhysicalRect, expected)
        XCTAssertGreaterThan(first.nativeStateFetchCount, 0)
        XCTAssertEqual(second.nativeStateFetchCount, 0)
    }

    @MainActor
    func testGeometryBurstKeepsEveryWindowAndTrailingEvent() async throws {
        setUpWorkspacesForTests()
        var scopes: [WindowRefreshScope] = []
        setScheduledRefreshOverrideForTests { _, _, scope in scopes.append(scope) }
        defer { setScheduledRefreshOverrideForTests(nil) }
        scheduleRefreshSession(moved, scope: .windows([1: 100]))
        scheduleRefreshSession(resized, scope: .windows([2: 200]))
        scheduleRefreshSession(moved, scope: .windows([1: 100]))
        try await waitForScheduledRefreshForTests()
        XCTAssertEqual(scopes, [.windows([1: 100]), .windows([1: 100, 2: 200])])
    }

    @MainActor
    func testLifecycleAndGlobalRequestsBroadenGeometryWork() async throws {
        setUpWorkspacesForTests()
        var scopes: [WindowRefreshScope] = []
        setScheduledRefreshOverrideForTests { _, _, scope in scopes.append(scope) }
        defer { setScheduledRefreshOverrideForTests(nil) }
        scheduleRefreshSession(moved, scope: .windows([1: 100]))
        scheduleRefreshSession(resized, scope: .windows([2: 200]))
        scheduleRefreshSession(.ax(kAXWindowCreatedNotification as String), scope: .apps([300]))
        try await waitForScheduledRefreshForTests()
        XCTAssertEqual(scopes, [.windows([1: 100]), .apps([200, 300])])
        scopes = []
        scheduleRefreshSession(moved, scope: .windows([1: 100]))
        scheduleRefreshSession(resized, scope: .windows([2: 200]))
        scheduleRefreshSession(.globalObserverLeftMouseUp)
        try await waitForScheduledRefreshForTests()
        XCTAssertEqual(scopes, [.windows([1: 100]), .all])
    }

    @MainActor
    func testUnidentifiedGeometryKeepsRecoveryBarrier() async throws {
        setUpWorkspacesForTests()
        TrayMenuModel.shared.isEnabled = true
        var discoveries = 0
        setBlockingRefreshOverridesForTests(refresh: { scope in
            XCTAssertEqual(scope, .all)
            discoveries += 1
        }, normalizeLayoutReason: { _ in })
        defer { setBlockingRefreshOverridesForTests() }
        try await runRefreshSessionBlocking(moved)
        XCTAssertEqual(discoveries, 1)
    }

    @MainActor
    func testNativeFullscreenTransitionStillNormalizesAffectedWindow() async throws {
        setUpWorkspacesForTests()
        TrayMenuModel.shared.isEnabled = true
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        window.nativeIsMacosFullscreen = true
        try await runRefreshSessionBlocking(resized, scope: .geometry(window))
        XCTAssertEqual(window.layoutReason, .macos(prevParentKind: .tilingContainer, prevWorkspaceName: focus.workspace.name))
    }
}
