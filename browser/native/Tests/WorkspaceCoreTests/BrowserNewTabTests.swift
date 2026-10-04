import Foundation
import WorkspaceCore
import XCTest

@MainActor final class BrowserNewTabTests: XCTestCase {
    func testEmptyInventoryCanCreateAndReturnsOwnerIdentityWithoutFabricatingInventory() {
        let epoch = UUID(), id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var requests: [BrowserNewTabRequest] = [], result: SurfaceID?
        let session = BrowserSurfaceSession(sendNewTab: { request, reply in requests.append(request); reply(.issued, id) }, send: { _, _ in XCTFail() })
        session.connect(epoch: epoch)
        session.supportsTabCreation = true
        XCTAssertTrue(session.reconcile(.init(revision: 2, full: true, tabs: []), epoch: epoch))
        XCTAssertEqual(session.openTab { reply, surface in XCTAssertEqual(reply, .issued); result = surface }, .issued)
        XCTAssertEqual(result, id)
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests[0].sourceSurfaceID)
        XCTAssertEqual(requests[0].revision, 2)
        XCTAssertTrue(session.inventory.tabs.isEmpty)
    }

    func testCreationRequiresV5AndRejectsInvalidSourceOrPayload() {
        let session = BrowserSurfaceSession(sendNewTab: { _, _ in XCTFail() }, send: { _, _ in XCTFail() })
        session.connect(epoch: UUID())
        XCTAssertEqual(session.openTab { reply, _ in XCTAssertEqual(reply, .unsupported) }, .unsupported)
        session.supportsTabCreation = true
        XCTAssertEqual(session.openTab(sourceSurfaceID: .nativeWindow(UUID())) { reply, _ in XCTAssertEqual(reply, .unavailable) }, .unavailable)
        XCTAssertEqual(session.openTab(url: "") { reply, _ in XCTAssertEqual(reply, .invalidRequest) }, .unsupported)
        XCTAssertEqual(session.openTab(url: String(repeating: "x", count: 16_385)) { _, _ in }, .unsupported)
    }

    func testRemovedSourceRetriesOnceWithExactProfileAfterFreshInventory() {
        let epoch = UUID(), profile = UUID(), source = SurfaceID.browserTab(profile: profile, tab: UUID())
        let created = SurfaceID.browserTab(profile: profile, tab: UUID())
        var requests: [BrowserNewTabRequest] = [], replies: [@MainActor (BrowserActionReply, SurfaceID?) -> Void] = [], outcomes: [BrowserActionReply] = []
        let session = BrowserSurfaceSession(sendNewTab: { request, reply in requests.append(request); replies.append(reply) }, send: { _, _ in })
        session.connect(epoch: epoch); session.supportsTabCreation = true
        XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: [.init(surfaceID: source, hostID: "host", title: "", selected: true)]), epoch: epoch))
        session.openTab(sourceSurfaceID: source, url: "https://example.test/") { reply, _ in outcomes.append(reply) }
        replies[0](.staleRevision, nil)
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(session.reconcile(.init(revision: 2, full: true, tabs: []), epoch: epoch))
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[1].sourceSurfaceID)
        XCTAssertEqual(requests[1].profileID, profile)
        XCTAssertEqual(requests[1].url, requests[0].url)
        XCTAssertNotEqual(requests[1].operation, requests[0].operation)
        replies[1](.issued, created)
        XCTAssertEqual(outcomes, [.issued])
        XCTAssertTrue(session.reconcile(.init(revision: 3, full: true, tabs: []), epoch: epoch))
        XCTAssertEqual(requests.count, 2)
    }

    func testReconnectAndMismatchedReturnedProfileCannotAssociateCreatedPin() {
        let profile = UUID(), id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var callback: (@MainActor (BrowserActionReply, SurfaceID?) -> Void)?
        let session = BrowserSurfaceSession(sendNewTab: { _, reply in callback = reply }, send: { _, _ in })
        session.connect(epoch: UUID()); session.supportsTabCreation = true
        session.openTab(profileID: profile) { reply, id in XCTAssertEqual(reply, .invalidRequest); XCTAssertNil(id) }
        callback?(.issued, id)
        session.openTab { reply, id in XCTAssertEqual(reply, .staleEpoch); XCTAssertNil(id) }
        session.connect(epoch: UUID())
        callback?(.issued, id)
    }
}
