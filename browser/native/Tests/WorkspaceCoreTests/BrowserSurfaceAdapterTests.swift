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

    func testBrowserControlsRequireCapabilityAndDoNotChangeFocusOrRemoveTab() {
        var requests: [BrowserActionRequest] = []
        let session = BrowserSurfaceSession { request, reply in requests.append(request); reply(.issued) }
        let epoch = UUID(), id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        session.connect(epoch: epoch)
        let tab = BrowserTabRecord(surfaceID: id, hostID: "host:1", title: "Page", selected: true,
                                   canGoBack: true, canGoForward: true)
        XCTAssertTrue(session.reconcile(.init(revision: 5, full: true, tabs: [tab]), epoch: epoch))
        XCTAssertEqual(session.request(.reload, surfaceID: id), .unsupported)
        XCTAssertTrue(requests.isEmpty)
        session.supportsBrowserControls = true
        for action: BrowserSurfaceAction in [.back, .forward, .reload, .stop, .extensions, .manageExtensions, .newTab] {
            XCTAssertEqual(session.request(action, surfaceID: id), .issued)
        }
        XCTAssertEqual(session.request(.navigate, surfaceID: id, url: "https://example.test/"), .issued)
        XCTAssertEqual(requests.last?.url, "https://example.test/")
        XCTAssertTrue(requests.allSatisfy { $0.epoch == epoch && $0.revision == 5 && $0.generation == 0 })
        XCTAssertEqual(Set(requests.map(\.operation)).count, requests.count)
        XCTAssertNil(session.focusIntent)
        XCTAssertNotNil(session.inventory.tabs[id])
    }

    func testInvalidNavigationPayloadAndUnavailableHistoryNeverReachTransport() {
        let session = BrowserSurfaceSession { _, _ in XCTFail("Invalid command reached transport") }
        let epoch = UUID(), id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        session.connect(epoch: epoch)
        session.supportsBrowserControls = true
        XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: [record(id)]), epoch: epoch))
        XCTAssertEqual(session.request(.back, surfaceID: id), .unavailable)
        XCTAssertEqual(session.request(.forward, surfaceID: id), .unavailable)
        XCTAssertEqual(session.request(.navigate, surfaceID: id), .unsupported)
        XCTAssertEqual(session.request(.navigate, surfaceID: id, url: ""), .unsupported)
        XCTAssertEqual(session.request(.navigate, surfaceID: id, url: String(repeating: "x", count: 16_385)), .unsupported)
        XCTAssertEqual(session.request(.close, surfaceID: id, url: "https://example.test/"), .unsupported)
        XCTAssertEqual(session.request(.cancelFocus, surfaceID: id), .unsupported)
    }

    func testStaleNavigationRetriesOnceAfterFreshInventoryWithoutReplayingIssuedActions() {
        var requests: [BrowserActionRequest] = []
        var replies: [@MainActor (BrowserActionReply) -> Void] = []
        var outcomes: [BrowserActionReply] = []
        let session = BrowserSurfaceSession { request, reply in requests.append(request); replies.append(reply) }
        let epoch = UUID(), id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        session.connect(epoch: epoch)
        session.supportsBrowserControls = true
        XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: [record(id)]), epoch: epoch))
        session.request(.navigate, surfaceID: id, url: "https://example.test/") { outcomes.append($0) }
        replies[0](.staleRevision)
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertTrue(session.reconcile(.init(revision: 2, full: false, tabs: [record(id)]), epoch: epoch))
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].url, requests[0].url)
        XCTAssertEqual(requests[1].revision, 2)
        XCTAssertNotEqual(requests[1].operation, requests[0].operation)
        replies[1](.staleRevision)
        XCTAssertEqual(outcomes, [.staleRevision])
        XCTAssertTrue(session.reconcile(.init(revision: 3, full: false, tabs: []), epoch: epoch))
        XCTAssertEqual(requests.count, 2)
        session.request(.reload, surfaceID: id) { outcomes.append($0) }
        replies[2](.issued)
        XCTAssertTrue(session.reconcile(.init(revision: 4, full: false, tabs: []), epoch: epoch))
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(outcomes, [.staleRevision, .issued])
    }

    func testPendingNavigationCannotCrossReconnectOrRetargetRemovedTab() {
        var requests: [BrowserActionRequest] = []
        var replies: [@MainActor (BrowserActionReply) -> Void] = []
        var outcomes: [BrowserActionReply] = []
        let session = BrowserSurfaceSession { request, reply in requests.append(request); replies.append(reply) }
        let epoch = UUID(), id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        session.connect(epoch: epoch)
        session.supportsBrowserControls = true
        XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: [record(id)]), epoch: epoch))
        session.request(.newTab, surfaceID: id) { outcomes.append($0) }
        replies[0](.staleRevision)
        XCTAssertTrue(session.reconcile(.init(revision: 2, full: false, tabs: [], removed: [id]), epoch: epoch))
        XCTAssertEqual(outcomes, [.unavailable])
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(session.reconcile(.init(revision: 3, full: false, tabs: [record(id)]), epoch: epoch))
        session.request(.newTab, surfaceID: id) { outcomes.append($0) }
        replies[1](.staleRevision)
        let nextEpoch = UUID()
        session.connect(epoch: nextEpoch)
        XCTAssertTrue(session.reconcile(.init(revision: 4, full: true, tabs: [record(id)]), epoch: nextEpoch))
        replies[1](.issued)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(outcomes, [.unavailable])
    }

    private func record(_ id: SurfaceID) -> BrowserTabRecord {
        BrowserTabRecord(surfaceID: id, hostID: "host:1", title: "Synthetic", selected: false)
    }
}
