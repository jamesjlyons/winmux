@testable import AppBundle
import XCTest

final class TrackpadSwipeRecognizerTest: XCTestCase {
    private func frame(_ time: Double, x: Double = 0.5, y: Double = 0.5, count: Int = 3, device: UInt = 1, button: Bool = false) -> TrackpadFrame {
        TrackpadFrame(device: device, timestamp: time,
            contacts: (0..<count).map { TrackpadContact(id: Int32($0), x: x, y: y) }, buttonDown: button)
    }

    func testSwitchesAtThresholdAndOnlyOnceUntilFullRelease() {
        var recognizer = TrackpadSwipeRecognizer()
        XCTAssertEqual(recognizer.observe(frame(0)), [.began(1)])
        XCTAssertEqual(recognizer.observe(frame(0.05, x: 0.3)), [.committed(1, .left)])
        XCTAssertEqual(recognizer.observe(frame(0.10, x: 0.8)), [])
        XCTAssertEqual(recognizer.observe(frame(0.15, count: 2)), [])
        XCTAssertEqual(recognizer.observe(frame(0.20)), [])
        XCTAssertEqual(recognizer.observe(frame(0.25, count: 0)), [.ended(1)])
        XCTAssertEqual(recognizer.observe(frame(0.30)), [.began(1)])
        XCTAssertEqual(recognizer.observe(frame(0.35, x: 0.7)), [.committed(1, .right)])
    }

    func testRequiresStableContactsAndRejectsShortMotion() {
        var recognizer = TrackpadSwipeRecognizer()
        _ = recognizer.observe(frame(0))
        XCTAssertEqual(recognizer.observe(frame(0.01, x: 0.3)), [])
        XCTAssertEqual(recognizer.observe(frame(0.05, x: 0.45)), [])
        XCTAssertEqual(recognizer.observe(frame(0.10, count: 0)), [.ended(1)])
    }

    func testVerticalAndDiagonalGesturesCannotLaterBecomeHorizontal() {
        for (x, y) in [(0.5, 0.7), (0.7, 0.7)] {
            var recognizer = TrackpadSwipeRecognizer()
            _ = recognizer.observe(frame(0))
            XCTAssertEqual(recognizer.observe(frame(0.05, x: x, y: y)), [.cancelled(1)])
            XCTAssertEqual(recognizer.observe(frame(0.10, x: 0.2)), [])
        }
    }

    func testTwoFingerScrollAndFourFingerGesturesNeverCommit() {
        for count in [1, 2, 4, 5] {
            var recognizer = TrackpadSwipeRecognizer()
            XCTAssertEqual(recognizer.observe(frame(0, count: count)), [])
            XCTAssertEqual(recognizer.observe(frame(0.05, x: 0.2, count: count)), [])
            XCTAssertEqual(recognizer.observe(frame(0.10, x: 0.2)), [])
            XCTAssertEqual(recognizer.observe(frame(0.15, x: 0.7)), [])
        }
    }

    func testAllowsStaggeredLandingWithoutPriorScroll() {
        var recognizer = TrackpadSwipeRecognizer()
        XCTAssertEqual(recognizer.observe(frame(0, count: 1)), [])
        XCTAssertEqual(recognizer.observe(frame(0.02, count: 2)), [])
        XCTAssertEqual(recognizer.observe(frame(0.04)), [.began(1)])
        XCTAssertEqual(recognizer.observe(frame(0.10, x: 0.3)), [.committed(1, .left)])
    }

    func testContactReplacementAndButtonPressCancelUntilRelease() {
        var recognizer = TrackpadSwipeRecognizer()
        _ = recognizer.observe(frame(0))
        let changed = TrackpadFrame(device: 1, timestamp: 0.05,
            contacts: (1...3).map { TrackpadContact(id: Int32($0), x: 0.3, y: 0.5) })
        XCTAssertEqual(recognizer.observe(changed), [.cancelled(1)])
        XCTAssertEqual(recognizer.observe(frame(0.1, x: 0.8)), [])
        _ = recognizer.observe(frame(0.15, count: 0))
        _ = recognizer.observe(frame(0.2))
        XCTAssertEqual(recognizer.observe(frame(0.25, x: 0.3, button: true)), [.cancelled(1)])
    }

    func testPartialLiftBeforeCommitCancels() {
        var recognizer = TrackpadSwipeRecognizer()
        _ = recognizer.observe(frame(0))
        XCTAssertEqual(recognizer.observe(frame(0.05, count: 2)), [.cancelled(1)])
        XCTAssertEqual(recognizer.observe(frame(0.10, x: 0.2)), [])
    }

    func testStaleOutOfOrderAndInvalidFramesCancel() {
        for badFrame in [frame(0.4, x: 0.3), frame(-0.01, x: 0.3), frame(0.05, x: .nan)] {
            var recognizer = TrackpadSwipeRecognizer()
            _ = recognizer.observe(frame(0))
            XCTAssertEqual(recognizer.observe(badFrame), [.cancelled(1)])
            XCTAssertEqual(recognizer.observe(frame(0.5, x: 0.2)), [])
        }
    }

    func testWatchdogExpiryAndLongGestureNeverRearmWithoutRelease() {
        var recognizer = TrackpadSwipeRecognizer()
        _ = recognizer.observe(frame(0))
        XCTAssertEqual(recognizer.expire(device: 1), [.cancelled(1)])
        XCTAssertEqual(recognizer.observe(frame(0.1, x: 0.2)), [])
        _ = recognizer.observe(frame(0.2, count: 0))
        _ = recognizer.observe(frame(0.3))
        for tick in 4...17 { _ = recognizer.observe(frame(Double(tick) / 10)) }
        XCTAssertEqual(recognizer.observe(frame(1.9, x: 0.2)), [.cancelled(1)])
    }

    func testOverlappingDevicesCancelBothSequences() {
        var recognizer = TrackpadSwipeRecognizer()
        _ = recognizer.observe(frame(0))
        XCTAssertEqual(recognizer.observe(frame(0.02, device: 2)), [.cancelled(1)])
        XCTAssertEqual(recognizer.observe(frame(0.05, x: 0.3)), [])
        XCTAssertEqual(recognizer.observe(frame(0.07, x: 0.3, device: 2)), [])
        _ = recognizer.observe(frame(0.1, count: 0))
        _ = recognizer.observe(frame(0.1, count: 0, device: 2))
        XCTAssertEqual(recognizer.observe(frame(0.15, device: 2)), [.began(2)])
        XCTAssertEqual(recognizer.observe(frame(0.2, x: 0.3, device: 2)), [.committed(2, .left)])
    }
}
