import Foundation
import WorkspaceCore
import XCTest

@MainActor
final class BrowserSurfaceAdapterTests: XCTestCase {
    func testCloseRetriesOnlyAnExplicitStaleRejectionForTheSameTab() {
        var requests: [BrowserActionRequest] = []
        var replies: [@MainActor (BrowserActionReply) -> Void] = []
        var outcomes: [BrowserActionReply] = []
        let session = BrowserSurfaceSession { request, reply in requests.append(request); replies.append(reply) }
        let epoch = UUID(), id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        session.connect(epoch: epoch)
        XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: [record(id)]), epoch: epoch))
        session.request(.close, surfaceID: id) { outcomes.append($0) }
        replies[0](.staleRevision)
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(session.reconcile(.init(revision: 2, full: false, tabs: []), epoch: epoch))
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].surfaceID, id)
        XCTAssertEqual(requests[1].epoch, epoch)
        XCTAssertEqual(requests[1].revision, 2)
        XCTAssertNotEqual(requests[1].operation, requests[0].operation)
        replies[1](.staleRevision)
        XCTAssertTrue(session.reconcile(.init(revision: 3, full: false, tabs: []), epoch: epoch))
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(outcomes, [.staleRevision])
        for outcome: BrowserActionReply in [.issued, .unavailable] {
            session.request(.close, surfaceID: id)
            replies.last?(outcome)
            let count = requests.count
            XCTAssertTrue(session.reconcile(.init(revision: session.inventory.revision + 1, full: false, tabs: []), epoch: epoch))
            XCTAssertEqual(requests.count, count)
        }
    }

    func testPendingCloseCannotCrossRemovalOrReconnect() {
        for reconnect in [false, true] {
            var requests: [BrowserActionRequest] = []
            var reply: (@MainActor (BrowserActionReply) -> Void)?
            let session = BrowserSurfaceSession { requests.append($0); reply = $1 }
            let epoch = UUID(), id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
            session.connect(epoch: epoch)
            XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: [record(id)]), epoch: epoch))
            session.request(.close, surfaceID: id)
            reply?(.staleRevision)
            if reconnect { session.connect(epoch: UUID()) }
            XCTAssertTrue(session.reconcile(.init(revision: 2, full: true, tabs: reconnect ? [record(id)] : []), epoch: session.epoch!))
            XCTAssertEqual(requests.count, 1)
        }
    }

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

    func testPrivacyControlsRequireNegotiatedCapabilityAndStayBoundToTheirPage() {
        var requests: [BrowserActionRequest] = []
        let session = BrowserSurfaceSession { request, reply in requests.append(request); reply(.issued) }
        let epoch = UUID(), id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        session.connect(epoch: epoch); session.supportsBrowserControls = true
        XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: [record(id)]), epoch: epoch))
        for action: BrowserSurfaceAction in [.search, .privacy, .keepActive, .siteBlocking] {
            XCTAssertEqual(session.request(action, surfaceID: id, url: "true"), .unsupported)
        }
        session.supportsPrivacy = true
        XCTAssertEqual(session.request(.keepActive, surfaceID: id, url: "true"), .issued)
        XCTAssertEqual(session.request(.siteBlocking, surfaceID: id, url: "false"), .issued)
        XCTAssertEqual(session.request(.search, surfaceID: id, url: "local query"), .issued)
        XCTAssertEqual(requests.map(\.surfaceID), [id, id, id])
        XCTAssertEqual(requests.map(\.url), ["true", "false", "local query"])
        XCTAssertNil(session.focusIntent)
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
        for action: BrowserSurfaceAction in [.minimize, .fullscreen, .zoom] {
            XCTAssertEqual(session.request(action, surfaceID: id), .unsupported)
        }
        XCTAssertTrue(requests.isEmpty)
        session.supportsBrowserControls = true
        for action: BrowserSurfaceAction in [.back, .forward, .reload, .stop, .extensions, .manageExtensions, .newTab, .minimize, .fullscreen, .zoom] {
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

    func testStaleFocusRetriesOnceWithFreshRevisionAndGeneration() {
        var requests: [BrowserActionRequest] = []
        var replies: [@MainActor (BrowserActionReply) -> Void] = []
        var outcomes: [BrowserActionReply] = []
        let session = BrowserSurfaceSession { requests.append($0); replies.append($1) }
        let epoch = UUID(), id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        session.connect(epoch: epoch)
        XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: [record(id)]), epoch: epoch))
        session.request(.focus, surfaceID: id) { outcomes.append($0) }
        replies[0](.staleRevision)
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertTrue(session.reconcile(.init(revision: 2, full: false, tabs: []), epoch: epoch))
        XCTAssertEqual(requests.map(\.generation), [1, 2])
        XCTAssertEqual(requests[1].revision, 2)
        XCTAssertEqual(requests[1].surfaceID, id)
        XCTAssertNotEqual(requests[1].operation, requests[0].operation)
        XCTAssertEqual(session.focusIntent?.request.operation, requests[1].operation)
        replies[1](.staleRevision)
        XCTAssertTrue(session.reconcile(.init(revision: 3, full: false, tabs: []), epoch: epoch))
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(outcomes, [.staleRevision])
    }

    func testStaleFocusUsesInventoryThatArrivedBeforeItsReply() {
        var requests: [BrowserActionRequest] = []
        var replies: [@MainActor (BrowserActionReply) -> Void] = []
        let session = BrowserSurfaceSession { requests.append($0); replies.append($1) }
        let epoch = UUID(), id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        session.connect(epoch: epoch)
        XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: [record(id)]), epoch: epoch))
        session.request(.focus, surfaceID: id)
        XCTAssertTrue(session.reconcile(.init(revision: 2, full: false, tabs: []), epoch: epoch))
        replies[0](.staleRevision)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].revision, 2)
        replies[1](.issued)
        XCTAssertEqual(session.focusIntent?.reply, .issued)
    }

    func testPendingStaleFocusCannotReplaceNewerBrowserSelection() {
        for replyBeforeSelection in [false, true] {
            var requests: [BrowserActionRequest] = []
            var replies: [@MainActor (BrowserActionReply) -> Void] = []
            var outcomes: [BrowserActionReply] = []
            let session = BrowserSurfaceSession { requests.append($0); replies.append($1) }
            let epoch = UUID(), profile = UUID()
            let a = SurfaceID.browserTab(profile: profile, tab: UUID()), b = SurfaceID.browserTab(profile: profile, tab: UUID())
            session.connect(epoch: epoch)
            XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: [record(a), record(b)]), epoch: epoch))
            session.request(.focus, surfaceID: a) { outcomes.append($0) }
            if replyBeforeSelection { replies[0](.staleRevision) }
            session.request(.focus, surfaceID: b)
            if !replyBeforeSelection { replies[0](.staleRevision) }
            XCTAssertTrue(session.reconcile(.init(revision: 2, full: false, tabs: []), epoch: epoch))
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(session.focusIntent?.request.surfaceID, b)
            XCTAssertEqual(outcomes, [.staleFocus])
        }
    }

    func testPendingStaleFocusCannotCrossNativeFocusFence() {
        var requests: [BrowserActionRequest] = []
        var replies: [@MainActor (BrowserActionReply) -> Void] = []
        let session = BrowserSurfaceSession { requests.append($0); replies.append($1) }
        let epoch = UUID(), id = SurfaceID.browserTab(profile: UUID(), tab: UUID()), native = SurfaceID.nativeWindow(UUID())
        session.connect(epoch: epoch)
        XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: [record(id)]), epoch: epoch))
        session.request(.focus, surfaceID: id)
        replies[0](.staleRevision)
        let generation = session.focusCoordinator.select(native)!
        session.supersedeFocus(generation: generation, target: native) { _ in }
        XCTAssertTrue(session.reconcile(.init(revision: 2, full: false, tabs: []), epoch: epoch))
        XCTAssertEqual(requests.map(\.action), [.focus, .cancelFocus])
        XCTAssertNil(session.focusIntent)
        XCTAssertEqual(session.focusCoordinator.target, native)
    }

    func testPendingStaleFocusCannotCrossAnotherBrowserConnection() {
        let clock = SurfaceFocusCoordinator()
        var requests: [BrowserActionRequest] = []
        var reply: (@MainActor (BrowserActionReply) -> Void)?
        let session = BrowserSurfaceSession(focusCoordinator: clock) { requests.append($0); reply = $1 }
        let other = BrowserSurfaceSession(focusCoordinator: clock) { _, done in done(.issued) }
        let epoch = UUID(), a = SurfaceID.browserTab(profile: UUID(), tab: UUID()), b = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        session.connect(epoch: epoch); other.connect(epoch: UUID())
        XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: [record(a)]), epoch: epoch))
        XCTAssertTrue(other.reconcile(.init(revision: 1, full: true, tabs: [record(b)]), epoch: other.epoch!))
        session.request(.focus, surfaceID: a)
        reply?(.staleRevision)
        other.request(.focus, surfaceID: b)
        XCTAssertTrue(session.reconcile(.init(revision: 2, full: false, tabs: []), epoch: epoch))
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(clock.target, b)
    }

    func testPendingStaleFocusCannotSurviveRemovalOrReconnect() {
        for reconnect in [false, true] {
            var requests: [BrowserActionRequest] = []
            var reply: (@MainActor (BrowserActionReply) -> Void)?
            let session = BrowserSurfaceSession { requests.append($0); reply = $1 }
            let epoch = UUID(), id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
            session.connect(epoch: epoch)
            XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: [record(id)]), epoch: epoch))
            session.request(.focus, surfaceID: id)
            reply?(.staleRevision)
            if reconnect { session.connect(epoch: UUID()) }
            XCTAssertTrue(session.reconcile(.init(revision: 2, full: true, tabs: reconnect ? [record(id)] : []), epoch: session.epoch!))
            XCTAssertEqual(requests.count, 1)
            XCTAssertNil(session.focusIntent)
        }
    }

    func testIssuedOrUncertainFocusIsNeverReplayed() {
        for outcome in [BrowserActionReply.issued, .unavailable] {
            var requests: [BrowserActionRequest] = []
            let session = BrowserSurfaceSession { request, reply in requests.append(request); reply(outcome) }
            let epoch = UUID(), id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
            session.connect(epoch: epoch)
            XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: [record(id)]), epoch: epoch))
            session.request(.focus, surfaceID: id)
            XCTAssertTrue(session.reconcile(.init(revision: 2, full: false, tabs: []), epoch: epoch))
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(session.focusIntent?.reply, outcome)
        }
    }

    func testPendingStaleFocusRespectsShellInputOwnership() {
        var requests: [BrowserActionRequest] = []
        var reply: (@MainActor (BrowserActionReply) -> Void)?
        var shellAllowsRetry = true
        let session = BrowserSurfaceSession(canRetryFocus: { shellAllowsRetry }) { requests.append($0); reply = $1 }
        let epoch = UUID(), id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        session.connect(epoch: epoch)
        XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: [record(id)]), epoch: epoch))
        session.request(.focus, surfaceID: id)
        reply?(.staleRevision)
        // Editing the Swift address field or dragging a pane owns input even
        // though the selected browser surface itself has not changed.
        shellAllowsRetry = false
        XCTAssertTrue(session.reconcile(.init(revision: 2, full: false, tabs: []), epoch: epoch))
        XCTAssertEqual(requests.count, 1)
    }

    private func record(_ id: SurfaceID) -> BrowserTabRecord {
        BrowserTabRecord(surfaceID: id, hostID: "host:1", title: "Synthetic", selected: false)
    }
}
