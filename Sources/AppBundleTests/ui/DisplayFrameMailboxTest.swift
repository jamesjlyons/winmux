@testable import AppBundle
import XCTest

final class DisplayFrameMailboxTest: XCTestCase {
    func testBurstQueuesOneDeliveryWithNewestTimestamp() {
        let mailbox = DisplayFrameMailbox()
        mailbox.start()
        let generation = mailbox.submit(1)!
        for tick in 2 ... 1000 { XCTAssertNil(mailbox.submit(Double(tick))) }
        XCTAssertEqual(mailbox.take(generation: generation), 1000)
        XCTAssertNil(mailbox.take(generation: generation))
        XCTAssertNotNil(mailbox.submit(1001))
    }

    func testStoppedAndOldGenerationCallbacksCannotReachNewSession() {
        let mailbox = DisplayFrameMailbox()
        XCTAssertNil(mailbox.submit(1))
        mailbox.start()
        let old = mailbox.submit(2)!
        mailbox.stop()
        XCTAssertNil(mailbox.submit(3))
        mailbox.start()
        let current = mailbox.submit(4)!
        XCTAssertNil(mailbox.take(generation: old))
        XCTAssertEqual(mailbox.take(generation: current), 4)
    }

    func testConcurrentTicksStillQueueOnlyOneDelivery() {
        let mailbox = DisplayFrameMailbox()
        mailbox.start()
        let first = mailbox.submit(0)!
        DispatchQueue.concurrentPerform(iterations: 1000) { tick in
            XCTAssertNil(mailbox.submit(Double(tick)))
        }
        XCTAssertEqual(mailbox.take(generation: first), 999)
    }
}
