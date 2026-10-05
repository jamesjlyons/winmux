import WorkspaceCore
import XCTest

final class WorkspaceSetupStartIntentTests: XCTestCase {
    func testPermissionAloneDoesNotCreateAStartupIntent() {
        var intent = WorkspaceSetupStartIntent()
        XCTAssertFalse(intent.consumePermissionGrant(accessibilityGranted: true))
    }

    func testExplicitStartWaitsForPermissionAndContinuesOnlyOnce() {
        var intent = WorkspaceSetupStartIntent()
        XCTAssertFalse(intent.request(accessibilityGranted: false))
        XCTAssertTrue(intent.awaitingAccessibility)
        XCTAssertFalse(intent.consumePermissionGrant(accessibilityGranted: false))
        XCTAssertTrue(intent.consumePermissionGrant(accessibilityGranted: true))
        XCTAssertFalse(intent.awaitingAccessibility)
        XCTAssertFalse(intent.consumePermissionGrant(accessibilityGranted: true))
    }

    func testCancelOrClosePreventsDelayedPermissionGrantFromStartingWorkspace() {
        var intent = WorkspaceSetupStartIntent()
        XCTAssertFalse(intent.request(accessibilityGranted: false))
        intent.cancel()
        XCTAssertFalse(intent.consumePermissionGrant(accessibilityGranted: true))
        XCTAssertTrue(intent.request(accessibilityGranted: true))
    }

    func testExistingPermissionAllowsExplicitStartWithoutASecondPrompt() {
        var intent = WorkspaceSetupStartIntent()
        XCTAssertTrue(intent.request(accessibilityGranted: true))
        XCTAssertFalse(intent.awaitingAccessibility)
        XCTAssertFalse(intent.consumePermissionGrant(accessibilityGranted: true))
    }
}
