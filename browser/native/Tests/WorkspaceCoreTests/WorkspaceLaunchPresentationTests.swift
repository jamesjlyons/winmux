import WorkspaceCore
import XCTest

final class WorkspaceLaunchPresentationTests: XCTestCase {
    func testNormalLaunchAndReadinessNeverRequireSetup() {
        XCTAssertEqual(WorkspaceLaunchPresentation.resolve(showSetup: false, failed: false,
            needsAccessibility: false, needsBackgroundApproval: false), .hidden)
    }

    func testPermissionSequenceReturnsToInvisibleStartup() {
        XCTAssertEqual(WorkspaceLaunchPresentation.resolve(showSetup: false, failed: false,
            needsAccessibility: true, needsBackgroundApproval: true), .accessibility)
        XCTAssertEqual(WorkspaceLaunchPresentation.resolve(showSetup: false, failed: false,
            needsAccessibility: false, needsBackgroundApproval: true), .backgroundApproval)
        XCTAssertEqual(WorkspaceLaunchPresentation.resolve(showSetup: false, failed: false,
            needsAccessibility: false, needsBackgroundApproval: false), .hidden)
    }

    func testOwnershipOrStartupFailureIsVisibleInsteadOfPromptingForPermissions() {
        XCTAssertEqual(WorkspaceLaunchPresentation.resolve(showSetup: false, failed: true,
            needsAccessibility: true, needsBackgroundApproval: true), .failure)
    }

    func testExplicitSetupRemainsAvailableInAnyLaunchState() {
        for failed in [false, true] {
            XCTAssertEqual(WorkspaceLaunchPresentation.resolve(showSetup: true, failed: failed,
                needsAccessibility: true, needsBackgroundApproval: true), .setup)
        }
    }

    func testDeadRegistrationCanRecoverOnceWithoutOpeningSetup() {
        for phase in ["ready", "failed", "stopped"] {
            XCTAssertTrue(workspaceShouldRecoverLaunch(automaticLaunch: true, ownsEnabledService: true,
                helperAlive: false, phase: phase, alreadyRetried: false))
            XCTAssertFalse(workspaceShouldRecoverLaunch(automaticLaunch: true, ownsEnabledService: true,
                helperAlive: false, phase: phase, alreadyRetried: true))
        }
    }

    func testRecoveryPreservesLiveOtherAndPendingWorkspaces() {
        XCTAssertFalse(workspaceShouldRecoverLaunch(automaticLaunch: true, ownsEnabledService: true,
            helperAlive: true, phase: "ready", alreadyRetried: false))
        XCTAssertFalse(workspaceShouldRecoverLaunch(automaticLaunch: true, ownsEnabledService: false,
            helperAlive: false, phase: "failed", alreadyRetried: false))
        XCTAssertFalse(workspaceShouldRecoverLaunch(automaticLaunch: false, ownsEnabledService: true,
            helperAlive: false, phase: "failed", alreadyRetried: false))
        for phase in [nil, "starting", "stopping", "needs_accessibility"] {
            XCTAssertFalse(workspaceShouldRecoverLaunch(automaticLaunch: true, ownsEnabledService: true,
                helperAlive: false, phase: phase, alreadyRetried: false))
        }
    }
}
