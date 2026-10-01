import Foundation
import WorkspaceCore
import XCTest

@MainActor
final class BrowserSurfaceAdapterTests: XCTestCase {
    func testLateAcknowledgementCannotReplaceNewerFocusIntent() {
        var requests: [BrowserActionRequest] = []
        var replies: [@MainActor (BrowserActionReply) -> Void] = []
        let session = BrowserSurfaceSession { request, reply in requests.append(request); replies.append(reply) }
        let epoch = UUID(), profile = UUID()
        let a = SurfaceID.browserTab(profile: profile, tab: UUID()), b = SurfaceID.browserTab(profile: profile, tab: UUID())
        session.connect(epoch: epoch)
        XCTAssertTrue(session.reconcile(.init(revision: 3, full: true, tabs: [record(a), record(b)]), epoch: epoch))
        XCTAssertEqual(BrowserTabSurfaceAdapter(surfaceID: a, session: session).requestFocus(), .issued)
        XCTAssertEqual(BrowserTabSurfaceAdapter(surfaceID: b, session: session).requestFocus(), .issued)
        XCTAssertEqual(requests.map(\.generation), [1, 2])
        replies[1](.issued)
        replies[0](.issued)
        XCTAssertEqual(session.focusIntent?.request.surfaceID, b)
        XCTAssertEqual(session.focusIntent?.reply, .issued)
    }

    func testClosureWaitsForOwnerAndRemovedIdentityCannotBeSelected() {
        let session = BrowserSurfaceSession { _, reply in reply(.issued) }
        let epoch = UUID(), id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        session.connect(epoch: epoch)
        XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: [record(id)]), epoch: epoch))
        let adapter = BrowserTabSurfaceAdapter(surfaceID: id, session: session)
        XCTAssertEqual(adapter.requestClose(), .issued)
        XCTAssertNotNil(session.inventory.tabs[id])
        XCTAssertTrue(session.reconcile(.init(revision: 2, full: false, tabs: [], removed: [id]), epoch: epoch))
        XCTAssertEqual(adapter.requestFocus(), .unavailable)
        XCTAssertEqual(adapter.requestClose(), .unavailable)
    }

    func testReconnectionRejectsOldInventoryDisconnectAndReply() {
        var completion: (@MainActor (BrowserActionReply) -> Void)?
        let session = BrowserSurfaceSession { _, reply in completion = reply }
        let old = UUID(), new = UUID(), id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        session.connect(epoch: old)
        let message = BrowserInventoryMessage(revision: 1, full: true, tabs: [record(id)])
        XCTAssertTrue(session.reconcile(message, epoch: old))
        XCTAssertEqual(BrowserTabSurfaceAdapter(surfaceID: id, session: session).requestFocus(), .issued)
        session.connect(epoch: new)
        session.disconnect(epoch: old)
        completion?(.issued)
        XCTAssertNil(session.focusIntent)
        XCTAssertEqual(session.epoch, new)
        XCTAssertFalse(session.reconcile(message, epoch: old))
        XCTAssertTrue(session.reconcile(message, epoch: new))
    }

    func testProfileOwnershipAndNativeIdentityCannotBeSubstituted() {
        let session = BrowserSurfaceSession { _, _ in XCTFail("Unavailable identity reached transport") }
        let epoch = UUID(), tab = UUID()
        session.connect(epoch: epoch)
        XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: [record(.browserTab(profile: UUID(), tab: tab))]), epoch: epoch))
        XCTAssertEqual(BrowserTabSurfaceAdapter(surfaceID: .browserTab(profile: UUID(), tab: tab), session: session).requestFocus(), .unavailable)
        XCTAssertEqual(BrowserTabSurfaceAdapter(surfaceID: .nativeWindow(tab), session: session).requestClose(), .unavailable)
    }

    private func record(_ id: SurfaceID) -> BrowserTabRecord {
        BrowserTabRecord(surfaceID: id, hostID: "host:1", title: "Synthetic", selected: false)
    }
}
