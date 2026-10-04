@testable import AppBundle
import Common
import XCTest

@MainActor
final class SessionPerformanceTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        TrayMenuModel.shared.isEnabled = true
        config.workspaceSidebar.enabled = false
        config.windowTabs.enabled = false
    }

    override func tearDown() async throws {
        appForTests = nil
        setScheduledRefreshOverrideForTests(nil)
    }

    func testExplicitGroupSelectionDoesNotQueryOutgoingAppOrScheduleDiscovery() async throws {
        let outgoing = FocusQueryProbeApp()
        appForTests = outgoing
        let first = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        _ = first.focusWindow()
        let destination = Workspace.get(byName: "destination")
        let target = TestWindow.new(id: 2, parent: destination.rootTilingContainer)
        var refreshes = 0
        setScheduledRefreshOverrideForTests { _, _, _ in refreshes += 1 }

        try await runLightSession(
            .menuBarButton, .forceRun,
            shouldSchedulePostRefresh: false,
            synchronizeNativeFocus: false
        ) {
            XCTAssertTrue(destination.focusWorkspace())
        }
        try await waitForScheduledRefreshForTests()

        XCTAssertEqual(outgoing.queries, 0)
        XCTAssertTrue(focus.workspace === destination)
        XCTAssertTrue(TestApp.shared.focusedWindow === target)
        XCTAssertGreaterThan(target.frameWriteCount, 0)
        XCTAssertEqual(refreshes, 0)
    }

    func testOrdinarySessionsStillReadActualNativeFocus() async throws {
        let outgoing = FocusQueryProbeApp()
        appForTests = outgoing
        try await runLightSession(.hotkeyBinding, .forceRun, shouldSchedulePostRefresh: false) {}
        XCTAssertEqual(outgoing.queries, 1)
    }

    func testPollingQueryKeepsNativeFocusAccurateWithoutPlacingWindows() async throws {
        let first = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let second = TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        _ = first.focusWindow()
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = second
        let command = parseCommand("list-windows --focused").cmdOrDie
        var refreshes = 0
        setScheduledRefreshOverrideForTests { _, _, _ in refreshes += 1 }

        let result = try await runSocketCommandSession(command, .forceRun) {
            XCTAssertTrue(focus.windowOrNil === second)
            return try await command.run(.defaultEnv, .emptyStdin)
        }
        try await waitForScheduledRefreshForTests()

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(first.frameWriteCount + second.frameWriteCount, 0)
        XCTAssertEqual(refreshes, 0)
    }

    func testConfigurationQueriesDoNotWaitForAXFocus() async throws {
        let outgoing = FocusQueryProbeApp()
        appForTests = outgoing
        let command = ListModesCommand(args: ListModesCmdArgs(rawArgs: []))
        let result = try await runSocketCommandSession(command, .forceRun) {
            try await command.run(.defaultEnv, .emptyStdin)
        }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(outgoing.queries, 0)
    }

    func testQueryDoesNotCancelPendingDiscovery() async throws {
        appForTests = nil
        let started = expectation(description: "Discovery started")
        var release: CheckedContinuation<Void, Never>?
        var wasCancelled = false
        var passes = 0
        setScheduledRefreshOverrideForTests { _, _, _ in
            passes += 1
            await withCheckedContinuation { release = $0; started.fulfill() }
            wasCancelled = Task.isCancelled
        }
        scheduleRefreshSession(.ax("AXWindowCreated"), scope: .apps([42]))
        await fulfillment(of: [started], timeout: 1)
        let command = ListModesCommand(args: ListModesCmdArgs(rawArgs: []))
        try await runSocketCommandSession(command, .forceRun) {}
        try XCTUnwrap(release).resume()
        try await waitForScheduledRefreshForTests()
        XCTAssertEqual(passes, 1)
        XCTAssertFalse(wasCancelled)
    }

    func testOnlyQueryCommandsTakeReadOnlyPath() {
        for text in ["list-modes", "list-apps", "list-windows --all", "list-workspaces --all", "config --get mode", "agent query", "agent skill", "surface list"] {
            XCTAssertTrue(parseCommand(text).cmdOrDie.isReadOnlyQuery, text)
        }
        for text in ["workspace next", "focus left", "layout tiles", "close", "agent apply --path /tmp/request.json", "surface focus selected", "surface close selected"] {
            XCTAssertFalse(parseCommand(text).cmdOrDie.isReadOnlyQuery, text)
        }
    }
}

private final class FocusQueryProbeApp: AbstractApp {
    let pid: Int32 = 9876
    let rawAppBundleId: String? = "test.focus-query"
    let name: String? = "Focus query probe"
    let execPath: String? = nil
    let bundlePath: String? = nil
    @MainActor var queries = 0
    @MainActor func getFocusedWindow() async throws -> Window? {
        queries += 1
        return nil
    }
}
