@testable import AppBundle
import XCTest

@MainActor
final class BrowserRefreshSchedulerTest: XCTestCase {
    func testInventoryBurstDoesNotOverlapSuspendedLayoutAndRunsOneTrailingPass() async throws {
        let started = expectation(description: "Initial layout suspended")
        var release: CheckedContinuation<Void, Never>?
        var passes = 0
        var active = 0
        var maximumActive = 0
        let scheduler = CoalescedBrowserRefreshScheduler {
            passes += 1
            active += 1
            maximumActive = max(maximumActive, active)
            if passes == 1 {
                await withCheckedContinuation { release = $0; started.fulfill() }
            }
            active -= 1
        }
        scheduler.schedule()
        await fulfillment(of: [started], timeout: 1)
        for _ in 0 ..< 1000 { scheduler.schedule() }
        XCTAssertEqual(passes, 1)
        try XCTUnwrap(release).resume()
        await scheduler.waitUntilIdle()
        XCTAssertEqual(passes, 2)
        XCTAssertEqual(maximumActive, 1)
        scheduler.schedule()
        await scheduler.waitUntilIdle()
        XCTAssertEqual(passes, 3)
    }

    func testBurstBeforeTaskStartsUsesOnePass() async {
        var passes = 0
        let scheduler = CoalescedBrowserRefreshScheduler { passes += 1 }
        for _ in 0 ..< 1000 { scheduler.schedule() }
        await scheduler.waitUntilIdle()
        XCTAssertEqual(passes, 1)
    }

    func testInventoryBeforeRuntimeReadyIsRetainedUntilExplicitStartupResume() async {
        var isReady = false
        var passes = 0
        let scheduler = CoalescedBrowserRefreshScheduler(isReady: { isReady }) { passes += 1 }
        for _ in 0 ..< 1000 { scheduler.schedule() }
        await scheduler.waitUntilIdle()
        XCTAssertEqual(passes, 0, "Do not consume inventory work while the native model is still initializing")

        isReady = true
        scheduler.resumePendingRefresh()
        await scheduler.waitUntilIdle()
        XCTAssertEqual(passes, 1, "Startup must publish early inventory without requiring another browser event")
        scheduler.resumePendingRefresh()
        await scheduler.waitUntilIdle()
        XCTAssertEqual(passes, 1, "Resuming an already drained startup must not repeat its layout")
    }

    func testReadinessLostDuringSuspendedPassPreservesTrailingInventory() async throws {
        var isReady = true
        var passes = 0
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "First pass suspended")
        let scheduler = CoalescedBrowserRefreshScheduler(isReady: { isReady }) {
            passes += 1
            if passes == 1 { await withCheckedContinuation { release = $0; started.fulfill() } }
        }
        scheduler.schedule()
        await fulfillment(of: [started], timeout: 1)
        isReady = false
        scheduler.schedule()
        try XCTUnwrap(release).resume()
        await scheduler.waitUntilIdle()
        XCTAssertEqual(passes, 1)
        isReady = true
        scheduler.resumePendingRefresh()
        await scheduler.waitUntilIdle()
        XCTAssertEqual(passes, 2)
    }

    func testStartupReadinessDoesNotWaitForTrailingInventoryToBecomeIdle() async throws {
        var isReady = false
        var passes = 0
        var releaseFirst: CheckedContinuation<Void, Never>?
        var releaseTrailing: CheckedContinuation<Void, Never>?
        let firstStarted = expectation(description: "Startup inventory pass suspended")
        let trailingStarted = expectation(description: "New inventory pass suspended")
        let startupCompleted = expectation(description: "Startup returns before later inventory settles")
        let scheduler = CoalescedBrowserRefreshScheduler(isReady: { isReady }) {
            passes += 1
            if passes == 1 {
                await withCheckedContinuation { releaseFirst = $0; firstStarted.fulfill() }
            } else if passes == 2 {
                await withCheckedContinuation { releaseTrailing = $0; trailingStarted.fulfill() }
            }
        }
        scheduler.schedule()
        isReady = true
        let startup = Task { @MainActor in
            await scheduler.resumePendingRefreshAndWaitForPass()
            startupCompleted.fulfill()
        }
        await fulfillment(of: [firstStarted], timeout: 1)
        for _ in 0 ..< 1000 { scheduler.schedule() }
        try XCTUnwrap(releaseFirst).resume()
        await fulfillment(of: [trailingStarted, startupCompleted], timeout: 1)
        XCTAssertEqual(passes, 2)

        // Inventory continues after readiness; it must still coalesce and drain.
        for _ in 0 ..< 1000 { scheduler.schedule() }
        try XCTUnwrap(releaseTrailing).resume()
        await scheduler.waitUntilIdle()
        await startup.value
        XCTAssertEqual(passes, 3)
    }
}
