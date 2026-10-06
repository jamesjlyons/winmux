import Foundation
import WorkspaceCore
import XCTest

@MainActor final class WorkspaceBrowserProfileTests: XCTestCase {
    func testSnapshotMigrationAndInvalidProfileReferences() throws {
        let old = #"{"tree":{"roots":{},"layouts":[],"activeSurfaces":[],"weights":{}},"layoutWorkspaces":[],"closedBrowserTabs":[]}"#
        var snapshot = try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: Data(old.utf8)).validated()
        XCTAssertTrue(snapshot.browserProfiles.isEmpty)
        XCTAssertTrue(snapshot.browserProfileBySpace.isEmpty)
        let profile = WorkspaceBrowserProfile(name: "Work")
        snapshot.browserProfiles = [profile]
        snapshot.browserProfileBySpace = ["one": profile.id, "two": profile.id]
        XCTAssertNoThrow(try snapshot.validated())
        snapshot.browserProfileBySpace["missing"] = UUID()
        XCTAssertThrowsError(try snapshot.validated())
        snapshot.browserProfileBySpace["missing"] = nil
        snapshot.browserProfiles.append(profile)
        XCTAssertThrowsError(try snapshot.validated())
        snapshot.browserProfileBySpace = [:]
        snapshot.browserProfiles = (0...WorkspaceBrowserProfile.maximumCount).map { .init(name: "Profile \($0)") }
        XCTAssertThrowsError(try snapshot.validated())
    }

    func testNamedRequestKeepsProfileAcrossRetryAndRejectsAnotherAccount() {
        let profile = WorkspaceBrowserProfile(name: "Work"), epoch = UUID()
        var requests: [BrowserNewTabRequest] = []
        var replies: [@MainActor (BrowserActionReply, SurfaceID?) -> Void] = []
        let session = BrowserSurfaceSession(sendNewTab: { request, reply in requests.append(request); replies.append(reply) }, send: { _, _ in })
        session.supportsTabCreation = true; session.supportsWorkspaceProfiles = true
        session.connect(epoch: epoch)
        XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: []), epoch: epoch))
        XCTAssertEqual(session.openTab(workspaceProfile: .named(profile)) { outcome, surface in
            XCTAssertEqual(outcome, .invalidRequest); XCTAssertNil(surface)
        }, .issued)
        replies[0](.staleRevision, nil)
        XCTAssertTrue(session.reconcile(.init(revision: 2, full: true, tabs: []), epoch: epoch))
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].workspaceProfile, .named(profile))
        XCTAssertNotEqual(requests[0].operation, requests[1].operation)
        replies[1](.issued, .browserTab(profile: UUID(), tab: UUID()))
    }

    func testWorkspaceRoutingRequiresVersionSixAndExcludesSourceAccount() {
        let session = BrowserSurfaceSession(sendNewTab: { _, _ in XCTFail() }, send: { _, _ in })
        session.connect(epoch: UUID()); session.supportsTabCreation = true
        XCTAssertEqual(session.openTab(workspaceProfile: .shared) { outcome, _ in XCTAssertEqual(outcome, .unsupported) }, .unsupported)
        session.supportsWorkspaceProfiles = true
        XCTAssertEqual(session.openTab(profileID: UUID(), workspaceProfile: .shared) { outcome, _ in
            XCTAssertEqual(outcome, .invalidRequest)
        }, .unsupported)
        XCTAssertEqual(session.openTab(workspaceProfile: .named(.init(name: ""))) { outcome, _ in
            XCTAssertEqual(outcome, .invalidRequest)
        }, .unsupported)
    }
}
