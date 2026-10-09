@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class WorkspaceSidebarSwipeTest: XCTestCase {
    func testPhasedSwipeCannotFinishOnPause() {
        let coordinator = WorkspaceSidebarProjectSwipeScrollCapture.Coordinator()
        var releases: [CGFloat] = []
        coordinator.onEnded = { horizontal, _ in releases.append(horizontal) }
        XCTAssertEqual(coordinator.gesture.update(deltaX: -30, deltaY: 0, phase: .began, momentum: []), .changed(-30, 0))
        XCTAssertFalse(coordinator.gesture.needsEndTimer)
        // Exercise the old 120 ms inactivity callback while fingers remain down.
        coordinator.finishLockedSwipe()
        XCTAssertTrue(releases.isEmpty)
        XCTAssertEqual(coordinator.gesture.update(deltaX: -30, deltaY: 0, phase: .changed, momentum: []), .changed(-60, 0))
        let release = coordinator.gesture.update(deltaX: 0, deltaY: 0, phase: .ended, momentum: [])
        XCTAssertTrue(coordinator.deliver(release))
        XCTAssertEqual(releases, [-60])
    }

    func testReleaseAndMomentumCannotStartASecondSwipe() {
        var gesture = WorkspaceSidebarProjectScrollGesture()
        XCTAssertEqual(gesture.update(deltaX: -80, deltaY: 0, phase: .began, momentum: []), .changed(-80, 0))
        XCTAssertEqual(gesture.update(deltaX: -5, deltaY: 0, phase: .ended, momentum: []), .ended(-85, 0))
        for momentum: NSEvent.Phase in [.began, .changed, .ended] {
            XCTAssertEqual(gesture.update(deltaX: -100, deltaY: 0, phase: [], momentum: momentum), .consumed)
        }
        for phase: NSEvent.Phase in [.changed, .ended, []] {
            XCTAssertEqual(gesture.update(deltaX: -80, deltaY: 0, phase: phase, momentum: []), .consumed)
        }
        XCTAssertEqual(gesture.update(deltaX: 60, deltaY: 0, phase: .began, momentum: []), .changed(60, 0))
        XCTAssertEqual(gesture.update(deltaX: 0, deltaY: 0, phase: .ended, momentum: []), .ended(60, 0))
    }

    func testCancellationSnapsBackEvenPastNavigationThreshold() {
        var gesture = WorkspaceSidebarProjectScrollGesture()
        _ = gesture.update(deltaX: 100, deltaY: 0, phase: .began, momentum: [])
        XCTAssertEqual(gesture.update(deltaX: 0, deltaY: 0, phase: .cancelled, momentum: []), .ended(0, 0))
        XCTAssertFalse(gesture.isLocked)
        XCTAssertEqual(gesture.update(deltaX: 90, deltaY: 0, phase: [], momentum: .began), .consumed)
    }

    func testDirectTransitionToMomentumFinishesOnceWithoutAddingInertia() {
        for phase: NSEvent.Phase in [[], .ended] {
            var gesture = WorkspaceSidebarProjectScrollGesture()
            _ = gesture.update(deltaX: -60, deltaY: 0, phase: .began, momentum: [])
            XCTAssertEqual(gesture.update(deltaX: -100, deltaY: 0, phase: phase, momentum: .began), .ended(-60, 0))
            XCTAssertEqual(gesture.update(deltaX: -100, deltaY: 0, phase: [], momentum: .changed), .consumed)
            XCTAssertEqual(gesture.update(deltaX: 0, deltaY: 0, phase: [], momentum: .ended), .consumed)
        }
    }

    func testVerticalScrollAndItsMomentumPassThrough() {
        var gesture = WorkspaceSidebarProjectScrollGesture()
        XCTAssertEqual(gesture.update(deltaX: 2, deltaY: 40, phase: .began, momentum: []), .passThrough)
        XCTAssertEqual(gesture.update(deltaX: 2, deltaY: 40, phase: .ended, momentum: []), .passThrough)
        XCTAssertEqual(gesture.update(deltaX: 2, deltaY: 40, phase: [], momentum: .began), .passThrough)
    }

    func testUnphasedPreciseScrollRetainsTimerFallback() {
        let coordinator = WorkspaceSidebarProjectSwipeScrollCapture.Coordinator()
        var releases: [CGFloat] = []
        coordinator.onEnded = { horizontal, _ in releases.append(horizontal) }
        _ = coordinator.gesture.update(deltaX: 70, deltaY: 0, phase: [], momentum: [])
        XCTAssertTrue(coordinator.gesture.needsEndTimer)
        coordinator.finishLockedSwipe()
        coordinator.finishLockedSwipe()
        XCTAssertEqual(releases, [70])
    }

    func testSettlementKeepsPagesUntilAnimationAndSelectionBothFinish() {
        for selectionFirst in [false, true] {
            var settlement = WorkspaceSidebarProjectSwipeSettlement(target: "next", direction: 1)
            XCTAssertFalse(settlement.isComplete)
            if selectionFirst { settlement.selectionConfirmed = true }
            else { settlement.animationFinished = true }
            XCTAssertFalse(settlement.isComplete)
            settlement.selectionConfirmed = true
            settlement.animationFinished = true
            XCTAssertTrue(settlement.isComplete)
        }
        var snapBack = WorkspaceSidebarProjectSwipeSettlement(target: nil, direction: -1)
        XCTAssertFalse(snapBack.isComplete)
        snapBack.animationFinished = true
        XCTAssertTrue(snapBack.isComplete)
    }
}
