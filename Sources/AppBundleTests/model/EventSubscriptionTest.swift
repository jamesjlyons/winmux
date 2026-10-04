@testable import AppBundle
import Foundation
import XCTest

@MainActor
final class EventSubscriptionTest: XCTestCase {
    private func event(_ index: Int) -> ServerEvent { .modeChanged(mode: String(index)) }
    private func bytes(_ event: ServerEvent) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(event)
    }

    func testSuspendedWriterPreservesOrderWithoutConcurrentSends() async throws {
        let started = expectation(description: "First write suspended")
        var release: CheckedContinuation<Bool, Never>?
        var written: [Data] = []
        let subscriber = EventSubscription(events: [.modeChanged], write: { event in
            written.append(self.bytes(event))
            if written.count == 1 {
                return await withCheckedContinuation { release = $0; started.fulfill() }
            }
            return true
        }, cancelTransport: {}, onClose: {})
        subscriber.enqueue(event(0))
        await fulfillment(of: [started], timeout: 1)
        for index in 1...20 { subscriber.enqueue(event(index)) }
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(subscriber.bufferedEventCount, 21)
        try XCTUnwrap(release).resume(returning: true)
        await subscriber.waitUntilIdle()
        XCTAssertEqual(written, (0...20).map { bytes(event($0)) })
        XCTAssertEqual(subscriber.bufferedEventCount, 0)
        XCTAssertFalse(subscriber.isClosed)
        subscriber.close()
    }

    func testSlowReaderHasBoundedQueueAndCancelsTransportOnOverflow() async {
        let started = expectation(description: "Blocked transport")
        var release: CheckedContinuation<Bool, Never>?
        var writes = 0
        var cancellations = 0
        var removals = 0
        let subscriber = EventSubscription(events: [.modeChanged], capacity: 3, write: { _ in
            writes += 1
            return await withCheckedContinuation { release = $0; started.fulfill() }
        }, cancelTransport: {
            cancellations += 1
            release?.resume(returning: false)
            release = nil
        }, onClose: { removals += 1 })
        subscriber.enqueue(event(0))
        await fulfillment(of: [started], timeout: 1)
        subscriber.enqueue(event(1))
        subscriber.enqueue(event(2))
        XCTAssertEqual(subscriber.bufferedEventCount, 3)
        subscriber.enqueue(event(3))
        for index in 4...1000 { subscriber.enqueue(event(index)) }
        await subscriber.waitUntilIdle()
        XCTAssertTrue(subscriber.isClosed)
        XCTAssertEqual(subscriber.bufferedEventCount, 0)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(removals, 1)
        subscriber.close()
        XCTAssertEqual(cancellations, 1)
    }

    func testSlowReaderDoesNotBlockHealthyClient() async {
        let started = expectation(description: "Slow client write suspended")
        var release: CheckedContinuation<Bool, Never>?
        let slow = EventSubscription(events: [.modeChanged], capacity: 2, write: { _ in
            await withCheckedContinuation { release = $0; started.fulfill() }
        }, cancelTransport: {
            release?.resume(returning: false)
            release = nil
        }, onClose: {})
        var received: [Data] = []
        var healthyCancellations = 0
        let healthy = EventSubscription(events: [.modeChanged], write: {
            received.append(self.bytes($0))
            return true
        }, cancelTransport: { healthyCancellations += 1 }, onClose: {})
        slow.enqueue(event(0))
        await fulfillment(of: [started], timeout: 1)
        for index in 1...3 {
            slow.enqueue(event(index))
            healthy.enqueue(event(index))
        }
        await healthy.waitUntilIdle()
        await slow.waitUntilIdle()
        XCTAssertTrue(slow.isClosed)
        XCTAssertFalse(healthy.isClosed)
        XCTAssertEqual(healthyCancellations, 0)
        XCTAssertEqual(received, (1...3).map { bytes(event($0)) })
        healthy.close()
    }

    func testDisconnectReleasesBlockedWriterAndRegistration() async {
        let started = expectation(description: "Write suspended before disconnect")
        var release: CheckedContinuation<Bool, Never>?
        var registered: EventSubscription?
        var cancellations = 0
        registered = EventSubscription(events: [.modeChanged], write: { _ in
            await withCheckedContinuation { release = $0; started.fulfill() }
        }, cancelTransport: {
            cancellations += 1
            release?.resume(returning: false)
            release = nil
        }, onClose: { registered = nil })
        weak var weakSubscriber = registered
        registered?.enqueue(event(0))
        await fulfillment(of: [started], timeout: 1)
        registered?.enqueue(event(1))
        registered?.close()
        XCTAssertNil(registered)
        await weakSubscriber?.waitUntilIdle()
        XCTAssertEqual(cancellations, 1)
        XCTAssertNil(weakSubscriber, "Cancelled socket write must not retain the subscription")
    }

    func testWriteFailureDropsQueuedEventsAndUnsubscribesOnce() async {
        var writes = 0
        var cancellations = 0
        var removals = 0
        let subscriber = EventSubscription(events: [.modeChanged], write: { _ in
            writes += 1
            return false
        }, cancelTransport: { cancellations += 1 }, onClose: { removals += 1 })
        subscriber.enqueue(event(0))
        subscriber.enqueue(event(1))
        await subscriber.waitUntilIdle()
        XCTAssertTrue(subscriber.isClosed)
        XCTAssertEqual(subscriber.bufferedEventCount, 0)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(removals, 1)
    }
}
