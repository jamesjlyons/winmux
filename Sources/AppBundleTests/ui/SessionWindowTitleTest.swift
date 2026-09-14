@testable import AppBundle
import XCTest

/// getSessionWindowTitle is the title accessor for per-session UI model builders: a known
/// window answers from the cache immediately (even past TTL — the stale entry is refreshed in
/// the background), while a first-sight window uses its app name until the background result arrives.
final class SessionWindowTitleTest: XCTestCase {
    @MainActor
    func testFirstSightReturnsImmediatelyAndFetchesInBackground() async {
        setUpWorkspacesForTests()
        resetCachedWindowTitles()
        let window = StubSessionTitleWindow(id: 61, title: "Inline")

        let title = getSessionWindowTitle(window)

        XCTAssertNil(title)
        XCTAssertEqual(window.titleGetCount, 0)
        await waitForBackgroundWindowTitlesForTests()
        XCTAssertEqual(cachedWindowTitle(for: window), "Inline")
        XCTAssertEqual(window.titleGetCount, 1)
    }

    @MainActor
    func testStaleEntryAnswersImmediatelyWithoutInlineFetch() async {
        setUpWorkspacesForTests()
        resetCachedWindowTitles()
        let window = StubSessionTitleWindow(id: 62, title: "Old")
        _ = await getCachedWindowTitle(window, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(window.titleGetCount, 1)

        window.stubTitle = "New"
        // Way past the 5s TTL: the session accessor must return the stale value synchronously
        // rather than blocking the session on an AX round-trip.
        let title = getSessionWindowTitle(window, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(title, "Old")
        XCTAssertEqual(window.titleGetCount, 1, "stale entry must not be refreshed inline")

        // The queued background refresh eventually updates the cache.
        for _ in 0 ..< 1000 {
            if cachedWindowTitle(for: window) == "New" { break }
            await Task.yield()
        }
        XCTAssertEqual(cachedWindowTitle(for: window), "New")
        XCTAssertEqual(window.titleGetCount, 2)
    }

    @MainActor
    func testFreshEntryDoesNotScheduleBackgroundRefresh() async {
        setUpWorkspacesForTests()
        resetCachedWindowTitles()
        let window = StubSessionTitleWindow(id: 63, title: "Fresh")
        let now = Date()
        _ = await getCachedWindowTitle(window, now: now)

        let title = getSessionWindowTitle(window, now: now.addingTimeInterval(1))
        XCTAssertEqual(title, "Fresh")

        for _ in 0 ..< 50 { await Task.yield() }
        XCTAssertEqual(window.titleGetCount, 1, "fresh entries must not be re-fetched")
    }
    @MainActor
    func testTwoConsumersShareOneSuspendedLookup() async throws {
        setUpWorkspacesForTests()
        let window = StubSessionTitleWindow(id: 70, title: "Shared")
        window.suspendLookup = true
        let first = Task { @MainActor in await getCachedWindowTitle(window) }
        let second = Task { @MainActor in await getCachedWindowTitle(window) }
        for _ in 0 ..< 1000 {
            if window.continuation != nil { break }
            await Task.yield()
        }
        let continuation = try XCTUnwrap(window.continuation)
        continuation.resume()
        let firstValue = await first.value
        let secondValue = await second.value
        XCTAssertEqual(firstValue, "Shared")
        XCTAssertEqual(secondValue, "Shared")
        XCTAssertEqual(window.titleGetCount, 1)
    }

    @MainActor
    func testResetRejectsLateTitleWithoutOverwritingNewResult() async throws {
        setUpWorkspacesForTests()
        let window = StubSessionTitleWindow(id: 71, title: "Old")
        window.suspendLookup = true
        let oldRead = Task { @MainActor in await getCachedWindowTitle(window) }
        for _ in 0 ..< 1000 {
            if window.continuation != nil { break }
            await Task.yield()
        }
        let continuation = try XCTUnwrap(window.continuation)
        resetCachedWindowTitles()
        window.suspendLookup = false
        window.stubTitle = "New"
        _ = await getCachedWindowTitle(window)
        continuation.resume()
        let stale = await oldRead.value
        XCTAssertNil(stale)
        XCTAssertEqual(cachedWindowTitle(for: window), "New")
    }

    @MainActor
    func testClosedWindowCannotPopulateReplacementTitleCache() async throws {
        setUpWorkspacesForTests()
        let old = StubSessionTitleWindow(id: 72, title: "Closed")
        old.suspendLookup = true
        let read = Task { @MainActor in await getCachedWindowTitle(old) }
        for _ in 0 ..< 1000 {
            if old.continuation != nil { break }
            await Task.yield()
        }
        let continuation = try XCTUnwrap(old.continuation)
        old.unbindFromParent()
        let replacement = StubSessionTitleWindow(id: 72, title: "Replacement")
        _ = await getCachedWindowTitle(replacement)
        continuation.resume()
        let stale = await read.value
        XCTAssertNil(stale)
        XCTAssertNil(cachedWindowTitle(for: old))
        XCTAssertEqual(cachedWindowTitle(for: replacement), "Replacement")
    }

    @MainActor
    func testFailedTitleLookupKeepsFallbackWithoutImmediateRetryLoop() async {
        setUpWorkspacesForTests()
        let window = StubSessionTitleWindow(id: 73, title: "")
        window.failLookup = true
        XCTAssertNil(getSessionWindowTitle(window))
        await waitForBackgroundWindowTitlesForTests()
        XCTAssertNil(getSessionWindowTitle(window))
        await waitForBackgroundWindowTitlesForTests()
        XCTAssertEqual(window.titleGetCount, 1)
    }

}

private final class StubSessionTitleWindow: Window {
    var stubTitle: String
    var titleGetCount: Int = 0
    var suspendLookup = false
    var failLookup = false
    var continuation: CheckedContinuation<Void, Never>?

    @MainActor
    init(id: UInt32, title: String) {
        stubTitle = title
        super.init(id: id, TestApp.shared, lastFloatingSize: nil, parent: Workspace.get(byName: "session-title-test"), adaptiveWeight: 1, index: INDEX_BIND_LAST)
    }

    override func closeAxWindow() {}

    @MainActor
    override var title: String {
        get async throws {
            titleGetCount += 1
            let value = stubTitle
            if suspendLookup { await withCheckedContinuation { continuation = $0 } }
            if failLookup { throw CancellationError() }
            return value
        }
    }

    @MainActor override var isMacosFullscreen: Bool { get async throws { false } }
    @MainActor override var isMacosMinimized: Bool { get async throws { false } }
}
