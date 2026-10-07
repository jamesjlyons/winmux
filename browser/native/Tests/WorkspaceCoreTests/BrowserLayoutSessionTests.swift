import Foundation
import XCTest
@testable import WorkspaceCore

final class BrowserLayoutSessionTests: XCTestCase {
    @MainActor private final class Fixture {
        var requests: [BrowserLayoutRequest] = []
        var replies: [@MainActor (BrowserActionReply) -> Void] = []
        final class Deadline {
            let delay: Duration
            let expired: @MainActor () -> Void
            var cancelled = false
            init(delay: Duration, expired: @escaping @MainActor () -> Void) {
                self.delay = delay
                self.expired = expired
            }
        }
        var deadlines: [Deadline] = []
        lazy var session = BrowserSurfaceSession(sendLayout: { [unowned self] request, reply in
            requests.append(request)
            replies.append(reply)
        }, send: { _, _ in })
        let surface = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let container = UUID()

        init() {
            session.scheduleLayoutDeadline = { [unowned self] delay, expired in
                let deadline = Deadline(delay: delay, expired: expired)
                deadlines.append(deadline)
                return { deadline.cancelled = true }
            }
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

    @MainActor func testIntegratedToolbarRequiresNegotiatedCapabilityAndNativeHostOwnership() throws {
        let fixture = Fixture()
        func hosts(nativeControls: Bool = true) -> [BrowserHostPlacement] {
            [.init(containerID: fixture.container, surfaces: [fixture.surface], selected: fixture.surface,
                   frame: .init(x: 10, y: 20, width: 600, height: 700), visible: true,
                   nativeControls: nativeControls, integratedToolbar: true)]
        }
        var outcome: BrowserActionReply?
        fixture.session.requestLayout(hosts()) { outcome = $0 }
        XCTAssertEqual(outcome, .unsupported)
        XCTAssertTrue(fixture.requests.isEmpty)
        fixture.session.supportsIntegratedToolbar = true
        outcome = nil
        fixture.session.requestLayout(hosts(nativeControls: false)) { outcome = $0 }
        XCTAssertEqual(outcome, .unsupported)
        XCTAssertTrue(fixture.requests.isEmpty)

        fixture.session.requestLayout(hosts()) { outcome = $0 }
        XCTAssertEqual(fixture.requests.count, 1)
        fixture.replies[0](.issued)
        XCTAssertEqual(outcome, .issued)
        let data = try JSONEncoder().encode(fixture.requests[0].hosts[0])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(legacy["integrated_toolbar"] as? Bool, true)
        legacy.removeValue(forKey: "integrated_toolbar")
        let decoded = try JSONDecoder().decode(BrowserHostPlacement.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(decoded.integratedToolbar, "Older wire records must retain their existing chrome contract")
        XCTAssertTrue(decoded.nativeControls)
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

    @MainActor func testInventoryAdvanceBeforeStaleReplyRetriesUnchangedPlan() {
        let fixture = Fixture(), hosts = fixture.hosts()
        fixture.session.requestLayout(hosts) { _ in }
        let epoch = fixture.requests[0].epoch
        XCTAssertTrue(fixture.session.reconcile(.init(revision: 2, full: false, tabs: []), epoch: epoch))
        var result: BrowserActionReply?
        fixture.session.requestLayout(hosts) { result = $0 }
        XCTAssertEqual(fixture.requests.count, 1, "Inventory refresh must keep layout transport serialized")

        fixture.replies[0](.staleRevision)

        XCTAssertEqual(fixture.requests.count, 2, "New inventory already arrived; no later event should be needed")
        guard fixture.requests.count == 2 else { return }
        XCTAssertEqual(fixture.requests[1].hosts, hosts)
        XCTAssertEqual(fixture.requests[1].revision, 2)
        XCTAssertGreaterThan(fixture.requests[1].generation, fixture.requests[0].generation)
        XCTAssertNotEqual(fixture.requests[1].operation, fixture.requests[0].operation)
        fixture.replies[1](.issued)
        XCTAssertEqual(result, .issued)
        fixture.session.requestLayout(hosts) { _ in XCTFail("The retried plan should be acknowledged") }
        XCTAssertEqual(fixture.requests.count, 2)
    }

    @MainActor func testStaleReplyWithoutNewInventoryWaitsForNextRevision() {
        let fixture = Fixture(), hosts = fixture.hosts()
        fixture.session.requestLayout(hosts) { _ in }
        fixture.replies[0](.staleRevision)
        fixture.session.requestLayout(hosts) { _ in }
        XCTAssertEqual(fixture.requests.count, 1, "A stale reply must not form a same-revision retry loop")

        let epoch = fixture.requests[0].epoch
        XCTAssertTrue(fixture.session.reconcile(.init(revision: 2, full: false, tabs: []), epoch: epoch))
        fixture.session.requestLayout(hosts) { _ in }
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertEqual(fixture.requests[1].revision, 2)
        fixture.replies[1](.staleRevision)
        fixture.session.requestLayout(hosts) { _ in }
        XCTAssertEqual(fixture.requests.count, 2)
    }

    @MainActor func testNewInventoryDoesNotRetryUnsupportedOrUnavailablePlan() {
        for outcome: BrowserActionReply in [.unsupported, .unavailable] {
            let fixture = Fixture(), hosts = fixture.hosts()
            fixture.session.requestLayout(hosts) { _ in }
            let epoch = fixture.requests[0].epoch
            XCTAssertTrue(fixture.session.reconcile(.init(revision: 2, full: false, tabs: []), epoch: epoch))
            fixture.session.requestLayout(hosts) { _ in }
            fixture.replies[0](outcome)
            XCTAssertEqual(fixture.requests.count, 1, "Only an explicitly stale revision warrants an immediate retry")
        }
    }

    @MainActor func testLostReplyRetriesLatestPlanAndInventoryWithoutRepeatingOldFocus() {
        let fixture = Fixture(), latest = fixture.hosts(x: 900)
        var result: BrowserActionReply?
        fixture.session.requestLayout(fixture.hosts()) { _ in XCTFail("Obsolete group must not receive focus") }
        let first = fixture.requests[0]
        fixture.session.requestLayout(latest) { result = $0 }
        XCTAssertTrue(fixture.session.reconcile(.init(revision: 2, full: false, tabs: []), epoch: first.epoch))

        fixture.deadlines[0].expired()

        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertEqual(fixture.requests[1].hosts, latest)
        XCTAssertEqual(fixture.requests[1].revision, 2)
        XCTAssertGreaterThan(fixture.requests[1].generation, first.generation)
        XCTAssertNotEqual(fixture.requests[1].operation, first.operation)
        XCTAssertEqual(fixture.session.layoutTimeoutCount, 1)
        XCTAssertNotNil(fixture.session.pendingLayoutMilliseconds)
        fixture.replies[0](.issued)
        XCTAssertNil(result, "A delayed old reply cannot acknowledge or focus the replacement")
        fixture.replies[1](.issued)
        XCTAssertEqual(result, .issued)
        XCTAssertNil(fixture.session.pendingLayoutMilliseconds)
        XCTAssertTrue(fixture.deadlines.allSatisfy(\.cancelled))
        fixture.session.requestLayout(latest) { _ in XCTFail("Recovered plan should be deduplicated") }
        XCTAssertEqual(fixture.requests.count, 2)
    }

    @MainActor func testLostReplyRecoveryIsBoundedAndNewPlanCanResume() {
        let fixture = Fixture(), hosts = fixture.hosts()
        var completions: [BrowserActionReply] = []
        fixture.session.requestLayout(hosts) { completions.append($0) }
        for index in 0..<3 { fixture.deadlines[index].expired() }

        XCTAssertEqual(fixture.deadlines.map(\.delay), [.seconds(1), .seconds(2), .seconds(4)])
        XCTAssertEqual(fixture.requests.count, 3, "A stalled owner cannot create an endless request loop")
        XCTAssertEqual(fixture.session.layoutTimeoutCount, 3)
        XCTAssertEqual(fixture.session.lastLayoutReply, .unavailable)
        XCTAssertNil(fixture.session.pendingLayoutMilliseconds)
        XCTAssertEqual(completions, [.unavailable])
        fixture.session.requestLayout(hosts) { _ in XCTFail("Same failed plan must wait for a change") }
        XCTAssertEqual(fixture.requests.count, 3)
        for reply in fixture.replies { reply(.issued) }
        XCTAssertEqual(completions, [.unavailable], "Late replies after exhaustion cannot focus")

        fixture.session.requestLayout(fixture.hosts(x: 900)) { completions.append($0) }
        XCTAssertEqual(fixture.requests.count, 4)
        XCTAssertEqual(fixture.deadlines.last?.delay, .seconds(1))
        fixture.replies[3](.issued)
        XCTAssertEqual(completions, [.unavailable, .issued])
    }

    @MainActor func testNewInventoryAllowsRecoveryAfterDeadlineBudgetExhausted() {
        let fixture = Fixture(), hosts = fixture.hosts()
        fixture.session.requestLayout(hosts) { _ in }
        for index in 0..<3 { fixture.deadlines[index].expired() }
        let epoch = fixture.requests[0].epoch
        XCTAssertTrue(fixture.session.reconcile(.init(revision: 2, full: false, tabs: []), epoch: epoch))
        fixture.session.requestLayout(hosts) { _ in }
        XCTAssertEqual(fixture.requests.count, 4)
        XCTAssertEqual(fixture.requests[3].revision, 2)
        XCTAssertEqual(fixture.deadlines.last?.delay, .seconds(1))
    }

    @MainActor func testNewGroupDuringFinalAttemptReceivesItsOwnRecoveryBudget() {
        let fixture = Fixture(), latest = fixture.hosts(x: 900)
        fixture.session.requestLayout(fixture.hosts()) { _ in XCTFail("Old group must not complete") }
        fixture.deadlines[0].expired()
        fixture.deadlines[1].expired()
        var result: BrowserActionReply?
        fixture.session.requestLayout(latest) { result = $0 }

        fixture.deadlines[2].expired()

        XCTAssertNil(result, "A group never attempted cannot exhaust the previous group's budget")
        XCTAssertEqual(fixture.requests.count, 4)
        XCTAssertEqual(fixture.requests[3].hosts, latest)
        XCTAssertEqual(fixture.deadlines[3].delay, .seconds(1))
        fixture.replies[3](.issued)
        XCTAssertEqual(result, .issued)
    }

    @MainActor func testNewRevisionDuringFinalAttemptIsNotMarkedAlreadyAttempted() {
        let fixture = Fixture(), hosts = fixture.hosts()
        fixture.session.requestLayout(hosts) { _ in }
        fixture.deadlines[0].expired()
        fixture.deadlines[1].expired()
        let epoch = fixture.requests[0].epoch
        XCTAssertTrue(fixture.session.reconcile(.init(revision: 2, full: false, tabs: []), epoch: epoch))
        var result: BrowserActionReply?
        fixture.session.requestLayout(hosts) { result = $0 }

        fixture.deadlines[2].expired()

        XCTAssertNil(result)
        XCTAssertEqual(fixture.requests.count, 4)
        XCTAssertEqual(fixture.requests[3].revision, 2)
        XCTAssertEqual(fixture.deadlines[3].delay, .seconds(1))
        fixture.replies[3](.issued)
        XCTAssertEqual(result, .issued)
    }

    @MainActor func testTimeoutRepairsReturningToPreviouslyAcknowledgedGroup() {
        let fixture = Fixture(), first = fixture.hosts(), second = fixture.hosts(x: 900)
        fixture.session.requestLayout(first) { _ in }
        fixture.replies[0](.issued)
        fixture.session.requestLayout(second) { _ in XCTFail("Timed-out group became obsolete") }
        var restored: BrowserActionReply?
        fixture.session.requestLayout(first) { restored = $0 }

        fixture.deadlines[1].expired()

        XCTAssertEqual(fixture.requests.count, 3, "The second group might have applied before its reply was lost")
        XCTAssertEqual(fixture.requests[2].hosts, first)
        fixture.replies[2](.issued)
        XCTAssertEqual(restored, .issued)
    }

    @MainActor func testInvalidationWithoutReplacementDoesNotReplayOnTimeout() {
        let fixture = Fixture()
        fixture.session.requestLayout(fixture.hosts()) { _ in XCTFail("Invalidated plan must not complete") }
        fixture.session.invalidateLayoutAcknowledgement()
        fixture.deadlines[0].expired()
        fixture.replies[0](.issued)
        XCTAssertEqual(fixture.requests.count, 1)
        fixture.session.requestLayout(fixture.hosts(x: 900)) { _ in }
        XCTAssertEqual(fixture.requests.count, 2)
    }

    @MainActor func testInvalidatedIdenticalReplacementRecoversAfterMissingReply() {
        let fixture = Fixture(), hosts = fixture.hosts()
        fixture.session.requestLayout(hosts) { _ in XCTFail("Invalidated completion must not run") }
        fixture.session.invalidateLayoutAcknowledgement()
        var result: BrowserActionReply?
        fixture.session.requestLayout(hosts) { result = $0 }
        fixture.deadlines[0].expired()
        fixture.replies[0](.issued)
        XCTAssertNil(result)
        fixture.replies[1](.issued)
        XCTAssertEqual(result, .issued)
    }

    @MainActor func testReplyAndDisconnectCancelDeadlinesAndFenceAlreadyQueuedExpirations() {
        let fixture = Fixture()
        fixture.session.requestLayout(fixture.hosts()) { _ in }
        fixture.replies[0](.issued)
        XCTAssertTrue(fixture.deadlines[0].cancelled)
        fixture.deadlines[0].expired()
        XCTAssertEqual(fixture.session.layoutTimeoutCount, 0)
        XCTAssertEqual(fixture.requests.count, 1)

        fixture.session.requestLayout(fixture.hosts(x: 900)) { _ in XCTFail("Disconnected request must not complete") }
        fixture.session.disconnect(epoch: fixture.requests[1].epoch)
        XCTAssertTrue(fixture.deadlines[1].cancelled)
        fixture.session.connect(epoch: UUID())
        fixture.deadlines[1].expired()
        fixture.replies[1](.issued)
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertEqual(fixture.session.layoutTimeoutCount, 0)
        XCTAssertNil(fixture.session.pendingLayoutMilliseconds)
    }
}
