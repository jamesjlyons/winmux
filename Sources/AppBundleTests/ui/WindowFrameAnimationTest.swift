@testable import AppBundle
import XCTest

final class WindowFrameAnimationTest: XCTestCase {
    private let start = CGRect(x: 40, y: 80, width: 600, height: 400)
    private let target = CGRect(x: 850, y: 30, width: 350, height: 700)

    func testMotionConvergesAtCommonDisplayRatesWithoutOvershoot() {
        for hz in [30.0, 60.0, 120.0, 144.0] {
            var motion = WindowFrameAnimation(from: start, to: target)
            var arrived = false
            var previous = start
            for _ in 0..<Int(hz) {
                arrived = motion.advance(by: 1 / hz, duration: 0.18)
                if arrived { break }
                let frame = motion.frame
                XCTAssertGreaterThanOrEqual(frame.minX, previous.minX)
                XCTAssertLessThanOrEqual(frame.minX, target.minX)
                XCTAssertGreaterThanOrEqual(frame.width, target.width)
                XCTAssertLessThanOrEqual(frame.height, target.height)
                previous = frame
            }
            XCTAssertTrue(arrived, "Did not arrive at \(hz) Hz")
            XCTAssertEqual(motion.target, target)
        }
    }

    func testAnalyticSpringIsIndependentOfTickFrequency() {
        var slow = WindowFrameAnimation(from: start, to: target)
        var fast = slow
        for _ in 0..<3 { _ = slow.advance(by: 1.0 / 30, duration: 0.18) }
        for _ in 0..<12 { _ = fast.advance(by: 1.0 / 120, duration: 0.18) }
        XCTAssertEqual(slow.frame, fast.frame)
    }

    func testRetargetKeepsPresentationAndMomentum() {
        var motion = WindowFrameAnimation(from: start, to: target)
        _ = motion.advance(by: 1.0 / 60, duration: 0.3)
        let before = motion.frame
        let reversedTarget = CGRect(x: -100, y: 80, width: 600, height: 400)
        motion.retarget(reversedTarget)
        XCTAssertEqual(motion.frame, before)
        _ = motion.advance(by: 0.001, duration: 0.3)
        // A restarted easing curve would immediately reverse; the spring keeps
        // its existing velocity and turns around smoothly.
        XCTAssertGreaterThan(motion.frame.minX, before.minX)
        var arrived = false
        for _ in 0..<120 {
            arrived = motion.advance(by: 1.0 / 120, duration: 0.3)
            if arrived { break }
        }
        XCTAssertTrue(arrived)
        XCTAssertEqual(motion.target, reversedTarget)
    }

    func testRepeatedIdenticalLayoutDoesNotRestartMotion() {
        var motion = WindowFrameAnimation(from: start, to: target)
        var uninterrupted = motion
        for _ in 0..<20 {
            motion.retarget(target)
            let arrived = motion.advance(by: 1.0 / 60, duration: 0.18)
            let expected = uninterrupted.advance(by: 1.0 / 60, duration: 0.18)
            XCTAssertEqual(arrived, expected)
            XCTAssertEqual(motion.frame, uninterrupted.frame)
        }
    }

    func testAdjacentWindowsKeepTheirSharedEdge() {
        var left = WindowFrameAnimation(from: CGRect(x: 0, y: 0, width: 600, height: 800),
                                       to: CGRect(x: 0, y: 0, width: 300, height: 800))
        var right = WindowFrameAnimation(from: CGRect(x: 608, y: 0, width: 400, height: 800),
                                        to: CGRect(x: 308, y: 0, width: 700, height: 800))
        for _ in 0..<20 {
            _ = left.advance(by: 1.0 / 120, duration: 0.18)
            _ = right.advance(by: 1.0 / 120, duration: 0.18)
            XCTAssertEqual(right.frame.minX - left.frame.maxX, 8)
        }
    }

    func testStalledDisplayAndZeroDurationFinishImmediately() {
        var stalled = WindowFrameAnimation(from: start, to: target)
        XCTAssertTrue(stalled.advance(by: 30, duration: 0.18))
        var disabled = WindowFrameAnimation(from: start, to: target)
        XCTAssertTrue(disabled.advance(by: 1.0 / 60, duration: 0))
    }

    func testShortDurationStaysFiniteAndKeepsExactFinalTarget() {
        let fractional = CGRect(x: -100.5, y: 40.25, width: 512.5, height: 320.25)
        var motion = WindowFrameAnimation(from: start, to: fractional)
        for _ in 0..<30 {
            _ = motion.advance(by: 1.0 / 144, duration: 0.001)
            XCTAssertTrue(motion.frame.isValidAnimationFrame)
        }
        XCTAssertEqual(motion.target, fractional)
    }

    func testAXFrameDoesNotInvertYAxis() {
        let rect = Rect(topLeftX: -1200, topLeftY: 80, width: 600, height: 400)
        XCTAssertEqual(rect.axAnimationFrame, CGRect(x: -1200, y: 80, width: 600, height: 400))
        XCTAssertFalse(CGRect(x: 0, y: 0, width: 0, height: 400).isValidAnimationFrame)
        XCTAssertFalse(CGRect(x: CGFloat.nan, y: 0, width: 600, height: 400).isValidAnimationFrame)
    }

    func testIntermediateWriterCorrectsSizeClampedByMove() throws {
        var actual = start
        try updateAnimatedWindowFrame(target, setPosition: {
            actual.origin = $0
            actual.size.width = 200 // Simulate macOS clamping on a monitor edge.
        }, setSize: { actual.size = $0 }, checkCancellation: {})
        XCTAssertEqual(actual, target)
    }

    func testKnownPreviousFrameOrdersWritesInsideBothFrames() throws {
        // `start` -> `target` is a mixed change and keeps the correcting write.
        let cases: [(from: CGRect, to: CGRect, writes: [String])] = [
            (start, CGRect(x: 60, y: 90, width: 500, height: 300), ["size", "position"]),
            (start, CGRect(x: 20, y: 70, width: 700, height: 500), ["position", "size"]),
            (start, CGRect(x: 90, y: 80, width: 600, height: 400), ["position"]),
            (start, CGRect(x: 40, y: 80, width: 640, height: 400), ["size"]),
            (start, start, []),
            (start, target, ["size", "position", "size"]),
        ]
        for (from, to, expected) in cases {
            var writes: [String] = [], actual = from
            var stayedInsideUnion = true
            try updateAnimatedWindowFrame(to, previous: from, setPosition: {
                actual.origin = $0
                writes.append("position")
                stayedInsideUnion = stayedInsideUnion && from.union(to).contains(actual)
            }, setSize: {
                actual.size = $0
                writes.append("size")
                stayedInsideUnion = stayedInsideUnion && from.union(to).contains(actual)
            }, checkCancellation: {})
            XCTAssertEqual(writes, expected, "\(from) -> \(to)")
            XCTAssertEqual(actual, to)
            XCTAssertTrue(stayedInsideUnion || writes.count == 3, "\(from) -> \(to)")
        }
    }

    func testWrittenFrameIsInexactAfterAnInterruptedWrite() {
        let written = AnimationWrittenFrame()
        XCTAssertNil(written.beginWrite())
        written.complete(start)
        XCTAssertEqual(written.beginWrite(), start)
        // The previous write never completed; only the last complete frame remains.
        XCTAssertNil(written.beginWrite())
        XCTAssertEqual(written.frame, start)
    }

    func testSupersededIntermediateFrameStopsBeforeEveryWrite() throws {
        for cancelAfter in 0...2 {
            var writes = 0
            XCTAssertThrowsError(try updateAnimatedWindowFrame(target,
                setPosition: { _ in writes += 1 }, setSize: { _ in writes += 1 },
                checkCancellation: { if writes == cancelAfter { throw CancellationError() } }))
            XCTAssertEqual(writes, cancelAfter)
        }
    }

    @MainActor
    func testAnimationConfigurationDefaultsAndOptOut() {
        let defaults = parseConfig("")
        XCTAssertTrue(defaults.errors.isEmpty)
        XCTAssertTrue(defaults.config.animations.enabled)
        XCTAssertEqual(defaults.config.animations.durationMs, 180)
        let custom = parseConfig("animations.enabled = false\nanimations.duration-ms = 0")
        XCTAssertTrue(custom.errors.isEmpty)
        XCTAssertFalse(custom.config.animations.enabled)
        XCTAssertEqual(custom.config.animations.durationMs, 0)
    }

    @MainActor
    func testAnimationConfigurationRejectsInvalidValues() {
        for value in ["-1", "1001", "1.5", "'fast'", "true"] {
            XCTAssertFalse(parseConfig("animations.duration-ms = \(value)").errors.isEmpty, value)
        }
        XCTAssertFalse(parseConfig("animations.enabled = 'yes'").errors.isEmpty)
        XCTAssertFalse(parseConfig("animations.unknown = true").errors.isEmpty)
        XCTAssertTrue(parseConfig("animations.duration-ms = 1000").errors.isEmpty)
    }
}

@MainActor
final class SharedStackChromeGlideTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        TrayMenuModel.shared.isEnabled = true
    }

    private func strip(_ id: WindowTabStripIdentity, at origin: CGPoint) -> WindowTabStripViewModel {
        .init(id: id, workspaceName: "w", frame: CGRect(origin: origin, size: CGSize(width: 400, height: 28)),
              groupFrame: CGRect(origin: origin, size: CGSize(width: 400, height: 300)), activeWindowId: nil,
              activeWindowCornerRadius: 0, tabs: [], occludingFloatingWindowFrames: [])
    }

    func testOnScreenStripGlidesFromItsPreviousFrameAndRevealsJump() throws {
        guard WindowLayoutAnimator.shared.browserHostAnimationMs > 0, let screen = NSScreen.screens.first?.frame else {
            throw XCTSkip("Motion is unavailable in this environment")
        }
        let glide = SharedStackChromeGlide {}
        defer { glide.cancelAll() }
        let id = WindowTabStripIdentity.shared(UUID())
        let a = CGPoint(x: screen.minX + 10, y: screen.minY + 10), b = CGPoint(x: screen.minX + 300, y: screen.minY + 10)
        XCTAssertEqual(glide.present(strip(id, at: a), isOnScreen: true).frame.origin, a)
        // The new destination starts from where the strip was shown.
        XCTAssertEqual(glide.present(strip(id, at: b), isOnScreen: true).groupFrame.origin, a)
        XCTAssertTrue(glide.isAnimating)
        // Hidden or revealed chrome takes its destination immediately.
        XCTAssertEqual(glide.present(strip(id, at: a), isOnScreen: false).frame.origin, a)
        XCTAssertFalse(glide.isAnimating)
    }
}
