@testable import AppBundle
import AppKit
import Common
import XCTest

final class WindowLifecycleRefreshTest: XCTestCase {
    private let created = RefreshSessionEvent.ax(kAXWindowCreatedNotification as String)
    private let destroyed = RefreshSessionEvent.ax(kAXUIElementDestroyedNotification as String)

    func testOnlyIdentifiedLifecycleEventsUseAppScope() {
        for notification in [kAXWindowCreatedNotification, kAXUIElementDestroyedNotification] {
            XCTAssertEqual(WindowRefreshScope.lifecycleNotification(notification, pid: 42), .apps([42]))
            XCTAssertEqual(WindowRefreshScope.lifecycleNotification(notification, pid: nil), .all)
        }
        XCTAssertEqual(WindowRefreshScope.lifecycleNotification(kAXWindowMiniaturizedNotification, pid: 42), .all)
        XCTAssertEqual(WindowRefreshScope.lifecycleNotification(kAXMovedNotification, pid: 42), .all)
    }

    @MainActor
    func testLifecycleSessionPassesScopeToDiscoveryAndNormalization() async throws {
        setUpWorkspacesForTests()
        TrayMenuModel.shared.isEnabled = true
        var discoveries: [WindowRefreshScope] = []
        var normalizations: [WindowRefreshScope] = []
        setBlockingRefreshOverridesForTests(
            refresh: { discoveries.append($0) },
            normalizeLayoutReason: { normalizations.append($0) }
        )
        defer { setBlockingRefreshOverridesForTests() }
        for event in [created, destroyed] {
            try await runRefreshSessionBlocking(event, scope: .apps([42]))
        }
        try await runRefreshSessionBlocking(.startup)
        XCTAssertEqual(discoveries, [.apps([42]), .apps([42]), .all])
        XCTAssertEqual(normalizations, discoveries)
    }

    @MainActor
    func testBurstsUnionAppsAndFocusDoesNotBroadenDiscovery() async throws {
        setUpWorkspacesForTests()
        var scopes: [WindowRefreshScope] = []
        setScheduledRefreshOverrideForTests { _, _, scope in
            scopes.append(scope)
        }
        defer { setScheduledRefreshOverrideForTests(nil) }
        scheduleRefreshSession(created, scope: .apps([1]))
        scheduleRefreshSession(created, scope: .apps([2]))
        scheduleRefreshSession(destroyed, scope: .apps([3]))
        scheduleRefreshSession(.onTabSwitched)
        try await waitForScheduledRefreshForTests()
        XCTAssertEqual(scopes, [.apps([1]), .apps([2, 3])])
    }

    @MainActor
    func testGlobalEventWinsOverPendingAppDiscovery() async throws {
        setUpWorkspacesForTests()
        var scopes: [WindowRefreshScope] = []
        setScheduledRefreshOverrideForTests { _, _, scope in scopes.append(scope) }
        defer { setScheduledRefreshOverrideForTests(nil) }
        scheduleRefreshSession(created, scope: .apps([1]))
        scheduleRefreshSession(destroyed, scope: .apps([2]))
        scheduleRefreshSession(.configAutoReload)
        scheduleRefreshSession(created, scope: .apps([3]))
        try await waitForScheduledRefreshForTests()
        XCTAssertEqual(scopes, [.apps([1]), .all])
    }

    @MainActor
    func testLightCommandPreservesInterruptedDiscoveryEvenWithoutPostRefresh() async throws {
        setUpWorkspacesForTests()
        TrayMenuModel.shared.isEnabled = true
        var scopes: [WindowRefreshScope] = []
        setScheduledRefreshOverrideForTests { _, _, scope in scopes.append(scope) }
        defer { setScheduledRefreshOverrideForTests(nil) }
        scheduleRefreshSession(created, scope: .apps([1]))
        scheduleRefreshSession(destroyed, scope: .apps([2]))
        try await runLightSession(.hotkeyBinding, .forceRun, shouldSchedulePostRefresh: false) {}
        try await waitForScheduledRefreshForTests()
        XCTAssertEqual(scopes, [.apps([1, 2])])
    }

    @MainActor
    func testNativeStateOfUnrelatedAppIsNotQueriedOrMutated() async throws {
        setUpWorkspacesForTests()
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        window.nativeIsMacosMinimized = true
        try await normalizeLayoutReason(scope: .apps([42]))
        XCTAssertEqual(window.nativeStateFetchCount, 0)
        XCTAssertTrue(window.parent === focus.workspace.rootTilingContainer)
        try await normalizeLayoutReason(scope: .apps([TestApp.shared.pid]))
        XCTAssertGreaterThan(window.nativeStateFetchCount, 0)
        XCTAssertTrue(window.parent === macosMinimizedWindowsContainer)
    }

    @MainActor
    func testUnrelatedSlowDiscoveryIsExcludedFromLifecycleBarrier() async throws {
        setUpWorkspacesForTests()
        TrayMenuModel.shared.isEnabled = true
        var queriedPids: [pid_t] = []
        setBlockingRefreshOverridesForTests(
            refresh: { scope in
                // Model an affected responsive app plus an unrelated slow app.
                for pid: pid_t in [1, 2] where scope.contains(pid) {
                    queriedPids.append(pid)
                    if pid == 2 { try await Task.sleep(for: .milliseconds(100)) }
                }
            },
            normalizeLayoutReason: { _ in }
        )
        defer { setBlockingRefreshOverridesForTests() }
        let clock = ContinuousClock()
        let globalStart = clock.now
        try await runRefreshSessionBlocking(created)
        let globalElapsed = globalStart.duration(to: clock.now)
        XCTAssertEqual(queriedPids, [1, 2])
        queriedPids = []
        let scopedStart = clock.now
        try await runRefreshSessionBlocking(created, scope: .apps([1]))
        let scopedElapsed = scopedStart.duration(to: clock.now)
        XCTAssertEqual(queriedPids, [1])
        // Report timing without a flaky wall-clock assertion; exclusion is the invariant.
        print("LIFECYCLE_REFRESH_BENCHMARK simulatedSlowApp=100ms global=\(globalElapsed) scoped=\(scopedElapsed)")
    }
}
