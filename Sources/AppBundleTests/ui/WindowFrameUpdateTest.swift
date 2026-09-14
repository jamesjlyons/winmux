@testable import AppBundle
import AppKit
import XCTest

final class WindowFrameUpdateTest: XCTestCase {
    func testMatchingFrameDoesNotWriteOrDisableAnimations() throws {
        let frame = FrameTransport()
        try frame.apply(position: frame.position, size: frame.size)
        XCTAssertEqual(frame.writes, [])
        XCTAssertEqual(frame.animationBlocks, 0)
    }

    func testPositionChangeDoesNotRewriteMatchingSize() throws {
        let frame = FrameTransport()
        try frame.apply(position: CGPoint(x: 30, y: 40), size: frame.size)
        XCTAssertEqual(frame.writes, ["position"])
    }

    func testResizeDoesNotWritePositionUnlessResizeMovedIt() throws {
        let frame = FrameTransport()
        try frame.apply(position: frame.position, size: CGSize(width: 800, height: 600))
        XCTAssertEqual(frame.writes, ["size"])
        frame.writes = []
        frame.shiftOnResize = true
        let target = frame.position
        try frame.apply(position: target, size: CGSize(width: 500, height: 400))
        XCTAssertEqual(frame.writes, ["size", "position"])
        XCTAssertEqual(frame.position, target)
    }

    func testMonitorMoveCorrectsClampedSize() throws {
        let frame = FrameTransport()
        frame.clampOnMove = true
        let targetSize = frame.size
        try frame.apply(position: CGPoint(x: 2000, y: 10), size: targetSize)
        XCTAssertEqual(frame.writes, ["position", "size"])
        XCTAssertEqual(frame.size, targetSize)
    }

    func testCancellationAfterResizeDoesNotApplyStalePosition() {
        let frame = FrameTransport()
        frame.cancelAfterWrite = true
        XCTAssertThrowsError(try frame.apply(position: CGPoint(x: 30, y: 40), size: CGSize(width: 800, height: 600)))
        XCTAssertEqual(frame.writes, ["size"])
    }
}

private final class FrameTransport {
    var position = CGPoint(x: 10, y: 20)
    var size = CGSize(width: 400, height: 300)
    var writes: [String] = []
    var animationBlocks = 0
    var shiftOnResize = false
    var clampOnMove = false
    var cancelAfterWrite = false

    func apply(position target: CGPoint?, size targetSize: CGSize?) throws {
        try updateWindowFrame(target, targetSize,
            getPosition: { self.position }, getSize: { self.size },
            setPosition: {
                self.position = $0
                self.writes.append("position")
                if self.clampOnMove { self.size.width = 200 }
            },
            setSize: {
                self.size = $0
                self.writes.append("size")
                if self.shiftOnResize { self.position.x += 1 }
            },
            checkCancellation: {
                if self.cancelAfterWrite && !self.writes.isEmpty { throw CancellationError() }
            },
            perform: { body in
                self.animationBlocks += 1
                try body()
            }
        )
    }
}
