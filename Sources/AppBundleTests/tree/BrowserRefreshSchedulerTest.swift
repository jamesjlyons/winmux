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
}
