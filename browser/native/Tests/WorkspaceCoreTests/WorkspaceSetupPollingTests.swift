import WorkspaceCore
import XCTest

final class WorkspaceSetupPollingTests: XCTestCase {
    func testAutomaticLaunchUsesFastChecksOnlyForFirstTenSeconds() {
        XCTAssertEqual(workspaceSetupRefreshInterval(automaticLaunchStartedAt: 100, now: 100), 0.1)
        XCTAssertEqual(workspaceSetupRefreshInterval(automaticLaunchStartedAt: 100, now: 109.999), 0.1)
        XCTAssertEqual(workspaceSetupRefreshInterval(automaticLaunchStartedAt: 100, now: 110), 1)
        XCTAssertEqual(workspaceSetupRefreshInterval(automaticLaunchStartedAt: 100, now: 1000), 1)
    }

    func testCompletedCancelledOrIdleLaunchUsesNormalCadenceImmediately() {
        XCTAssertEqual(workspaceSetupRefreshInterval(automaticLaunchStartedAt: nil, now: 100), 1)
        XCTAssertEqual(workspaceSetupRefreshInterval(automaticLaunchStartedAt: nil, now: 105), 1)
    }

    func testFreshRequestGetsNewBoundedWindowWithoutExtendingOldRequest() {
        XCTAssertEqual(workspaceSetupRefreshInterval(automaticLaunchStartedAt: 100, now: 115), 1)
        XCTAssertEqual(workspaceSetupRefreshInterval(automaticLaunchStartedAt: 115, now: 115), 0.1)
        XCTAssertEqual(workspaceSetupRefreshInterval(automaticLaunchStartedAt: 115, now: 125), 1)
        XCTAssertEqual(workspaceSetupRefreshInterval(automaticLaunchStartedAt: 115, now: 114), 1)
    }
}
