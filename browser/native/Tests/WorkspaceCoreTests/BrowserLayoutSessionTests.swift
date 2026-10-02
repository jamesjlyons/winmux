import Foundation
import XCTest
@testable import WorkspaceCore

final class BrowserLayoutSessionTests: XCTestCase {
    @MainActor private final class Fixture {
        var requests: [BrowserLayoutRequest] = []
        var replies: [@MainActor (BrowserActionReply) -> Void] = []
        lazy var session = BrowserSurfaceSession(sendLayout: { [unowned self] request, reply in
            requests.append(request)
            replies.append(reply)
        }, send: { _, _ in })
        let surface = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let container = UUID()

        init() {
            session.supportsLayout = true
            let epoch = UUID()
            session.connect(epoch: epoch)
            XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: []), epoch: epoch))
        }

        func hosts(x: Int = 10) -> [BrowserHostPlacement] {
            [.init(containerID: container, surfaces: [surface], selected: surface,
                   frame: .init(x: x, y: 20, width: 600, height: 700), visible: true)]
        }
    }

    @MainActor func testDriftInvalidationReappliesAcknowledgedFrameAtSameInventoryRevision() {
        let fixture = Fixture(), hosts = fixture.hosts()
        fixture.session.requestLayout(hosts) { _ in }
        fixture.replies[0](.issued)
        fixture.session.requestLayout(hosts) { _ in XCTFail("An unchanged acknowledged plan should be deduplicated") }
        XCTAssertEqual(fixture.requests.count, 1)

        fixture.session.invalidateLayoutAcknowledgement()
        XCTAssertEqual(fixture.requests.count, 1, "Invalidation must wait for the caller's fresh plan")
        var repaired = false
        fixture.session.requestLayout(hosts) { repaired = $0 == .issued }
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertEqual(fixture.requests[1].hosts, hosts)
        XCTAssertEqual(fixture.requests[1].revision, fixture.requests[0].revision)
        XCTAssertGreaterThan(fixture.requests[1].generation, fixture.requests[0].generation)
        XCTAssertNotEqual(fixture.requests[1].operation, fixture.requests[0].operation)
        fixture.replies[1](.issued)
        XCTAssertTrue(repaired)
        fixture.session.requestLayout(hosts) { _ in XCTFail("The repaired plan should be acknowledged") }
        XCTAssertEqual(fixture.requests.count, 2)
    }

    @MainActor func testInvalidatedInFlightReplyCannotAcknowledgeIdenticalReplacement() {
        let fixture = Fixture(), hosts = fixture.hosts()
        var completions: [String] = []
        fixture.session.requestLayout(hosts) { _ in completions.append("obsolete") }
        fixture.session.invalidateLayoutAcknowledgement()
        fixture.session.requestLayout(hosts) { _ in completions.append("replacement") }
        XCTAssertEqual(fixture.requests.count, 1, "Only one transport request can be in flight")

        fixture.replies[0](.issued)
        XCTAssertTrue(completions.isEmpty, "The obsolete reply must not signal presentation readiness")
        XCTAssertEqual(fixture.requests.count, 2, "Identical hosts still need dispatch after invalidation")
        XCTAssertEqual(fixture.requests[1].hosts, hosts)
        fixture.replies[1](.issued)
        XCTAssertEqual(completions, ["replacement"])
        fixture.session.requestLayout(hosts) { _ in XCTFail("Replacement was already acknowledged") }
        XCTAssertEqual(fixture.requests.count, 2)
    }

    @MainActor func testInvalidationWithoutFreshPlanDoesNotReplayWhenOldReplyArrives() {
        let fixture = Fixture(), hosts = fixture.hosts()
        fixture.session.requestLayout(hosts) { _ in XCTFail("Invalidated completion must not run") }
        fixture.session.invalidateLayoutAcknowledgement()
        fixture.replies[0](.issued)
        XCTAssertEqual(fixture.requests.count, 1, "No old desired plan may be replayed after invalidation")
        fixture.session.requestLayout(hosts) { _ in }
        XCTAssertEqual(fixture.requests.count, 2)
    }

    @MainActor func testRepeatedInvalidationCoalescesToLatestPlanDespiteStaleRevisionReply() {
        let fixture = Fixture(), initial = fixture.hosts(), latest = fixture.hosts(x: 900)
        fixture.session.requestLayout(initial) { _ in XCTFail("Original request is obsolete") }
        fixture.session.invalidateLayoutAcknowledgement()
        fixture.session.requestLayout(initial) { _ in XCTFail("Intermediate repair is obsolete") }
        fixture.session.invalidateLayoutAcknowledgement()
        var completed: BrowserActionReply?
        fixture.session.requestLayout(latest) { completed = $0 }
        fixture.replies[0](.staleRevision)
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertEqual(fixture.requests[1].hosts, latest)
        fixture.replies[1](.issued)
        XCTAssertEqual(completed, .issued)
        fixture.replies[0](.issued)
        XCTAssertEqual(fixture.requests.count, 2, "A duplicate stale reply cannot reopen the transport")
    }

    @MainActor func testFailedRepairDoesNotRetryUntilExplicitlyInvalidatedAgain() {
        let fixture = Fixture(), hosts = fixture.hosts()
        fixture.session.requestLayout(hosts) { _ in }
        fixture.replies[0](.issued)
        fixture.session.invalidateLayoutAcknowledgement()
        var result: BrowserActionReply?
        fixture.session.requestLayout(hosts) { result = $0 }
        fixture.replies[1](.unavailable)
        XCTAssertEqual(result, .unavailable)
        fixture.session.requestLayout(hosts) { _ in }
        XCTAssertEqual(fixture.requests.count, 2, "A failed repair must not form a same-revision retry loop")
        fixture.session.invalidateLayoutAcknowledgement()
        fixture.session.requestLayout(hosts) { _ in }
        XCTAssertEqual(fixture.requests.count, 3)
    }
}
