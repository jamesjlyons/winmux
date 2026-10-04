@testable import AppBundle
import Common
import XCTest

@MainActor
final class MonitorConfigurationObserverTest: XCTestCase {
    func testStartupMonitorPolicyDoesNotScheduleDuplicateDiscovery() async throws {
        setUpWorkspacesForTests()
        let wasReady = isWinMuxRuntimeReady
        let wasEnabled = TrayMenuModel.shared.isEnabled
        defer {
            isWinMuxRuntimeReady = wasReady
            TrayMenuModel.shared.isEnabled = wasEnabled
            setScheduledRefreshOverrideForTests(nil)
        }
        TrayMenuModel.shared.isEnabled = true
        config.workspaceSidebar.enabled = false
        config.windowTabs.enabled = false
        var refreshes: [RefreshSessionEvent] = []
        setScheduledRefreshOverrideForTests { event, _, scope in
            XCTAssertTrue(scope.requiresDiscovery)
            refreshes.append(event)
        }

        isWinMuxRuntimeReady = false
        MonitorConfigurationObserver.shared.prepareForStartup()
        try await waitForScheduledRefreshForTests()
        XCTAssertTrue(refreshes.isEmpty, "Startup's explicit discovery must remain the only initial scan")
    }
}
