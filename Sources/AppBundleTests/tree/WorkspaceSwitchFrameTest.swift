@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class WorkspaceSwitchFrameTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testRepeatedGroupRestoresQueueFramesWithoutRepeatedNativeProbes() async throws {
        let window = TestWindow.new(id: 901, parent: focus.workspace.rootTilingContainer)
        let rect = Rect(topLeftX: 44, topLeftY: 28, width: 800, height: 600)
        var applies = 0, observations = 0
        try await $refreshSessionEvent.withValue(.menuBarButton) {
            for _ in 0..<20 {
                // Hiding a group clears its active layout frame, but its accepted
                // native size remains valid when the same group is shown again.
                window.lastAppliedLayoutPhysicalRect = nil
                _ = try await window.applyObservedSharedLayoutFrame(rect, apply: {
                    applies += 1
                    window.setAxFrame(rect.topLeftCorner, rect.size)
                }, observe: {
                    observations += 1
                    return rect
                })
            }
        }
        XCTAssertEqual(applies, 1)
        XCTAssertEqual(observations, 1)
        XCTAssertEqual(window.frameWriteCount, 20)
        XCTAssertEqual(window.lastAppliedLayoutPhysicalRect, rect)
    }

    func testResizeAndNativeGeometryEventsRecheckAcceptedSize() async throws {
        let window = TestWindow.new(id: 902, parent: focus.workspace.rootTilingContainer)
        var rect = Rect(topLeftX: 44, topLeftY: 28, width: 800, height: 600)
        var observations = 0
        func apply() async throws {
            _ = try await window.applyObservedSharedLayoutFrame(rect, apply: {}, observe: {
                observations += 1
                return rect
            })
        }
        try await $refreshSessionEvent.withValue(.menuBarButton) {
            try await apply()
            rect.width = 900
            try await apply()
        }
        try await $refreshSessionEvent.withValue(.ax(kAXResizedNotification as String)) {
            try await apply()
        }
        XCTAssertEqual(observations, 3)
        XCTAssertEqual(window.lastConfirmedSharedLayoutSize, rect.size)
    }

    func testClampedNativeSizeDoesNotBecomeAnAcceptedFrame() async throws {
        let window = TestWindow.new(id: 903, parent: focus.workspace.rootTilingContainer)
        let rect = Rect(topLeftX: 44, topLeftY: 28, width: 100, height: 100)
        let clamped = Rect(topLeftX: 44, topLeftY: 28, width: 300, height: 200)
        var observations = 0
        try await $refreshSessionEvent.withValue(.menuBarButton) {
            for _ in 0..<2 {
                let actual = try await window.applyObservedSharedLayoutFrame(rect, apply: {}, observe: {
                    observations += 1
                    return clamped
                })
                XCTAssertEqual(actual, clamped)
            }
        }
        XCTAssertEqual(observations, 2)
        XCTAssertNil(window.lastConfirmedSharedLayoutSize)
    }

    func testCancelledObservationClearsOldAcceptedSizeAndRequestedFrame() async throws {
        let window = TestWindow.new(id: 904, parent: focus.workspace.rootTilingContainer)
        let rect = Rect(topLeftX: 44, topLeftY: 28, width: 800, height: 600)
        window.lastConfirmedSharedLayoutSize = rect.size
        do {
            _ = try await $refreshSessionEvent.withValue(.startup) {
                try await window.applyObservedSharedLayoutFrame(rect, apply: {}, observe: { throw CancellationError() })
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertNil(window.lastConfirmedSharedLayoutSize)
        XCTAssertNil(window.lastAppliedLayoutPhysicalRect)
    }

    func testHiddenResizeInvalidatesAcceptedSizeButParkingMoveDoesNot() async throws {
        let window = TestWindow.new(id: 906, parent: focus.workspace.rootTilingContainer)
        let rect = Rect(topLeftX: 44, topLeftY: 28, width: 800, height: 600)
        window.lastConfirmedSharedLayoutSize = rect.size
        window.lastAppliedLayoutPhysicalRect = nil
        window.invalidateLastKnownNativeState()
        XCTAssertEqual(window.lastConfirmedSharedLayoutSize, rect.size)
        window.invalidateLastKnownNativeState(includingSharedLayoutSize: true)
        var observations = 0
        _ = try await $refreshSessionEvent.withValue(.menuBarButton) {
            try await window.applyObservedSharedLayoutFrame(rect, apply: {}, observe: {
                observations += 1
                return Rect(topLeftX: 44, topLeftY: 28, width: 1000, height: 600)
            })
        }
        XCTAssertEqual(observations, 1)
        XCTAssertNil(window.lastConfirmedSharedLayoutSize)
    }

    func testResizeDuringObservationCannotRestoreAcceptedSize() async throws {
        let window = TestWindow.new(id: 907, parent: focus.workspace.rootTilingContainer)
        let rect = Rect(topLeftX: 44, topLeftY: 28, width: 800, height: 600)
        _ = try await window.applyObservedSharedLayoutFrame(rect, apply: {}, observe: {
            window.invalidateLastKnownNativeState(includingSharedLayoutSize: true)
            return rect
        })
        XCTAssertNil(window.lastConfirmedSharedLayoutSize)
    }

    func testSupersededObservationCannotCacheAnObsoleteFrame() async throws {
        let window = TestWindow.new(id: 905, parent: focus.workspace.rootTilingContainer)
        let rect = Rect(topLeftX: 44, topLeftY: 28, width: 800, height: 600)
        let newer = Rect(topLeftX: 800, topLeftY: 28, width: 900, height: 600)
        _ = try await window.applyObservedSharedLayoutFrame(rect, apply: {}, observe: {
            window.lastAppliedLayoutPhysicalRect = newer
            return rect
        })
        XCTAssertNil(window.lastConfirmedSharedLayoutSize)
        XCTAssertEqual(window.lastAppliedLayoutPhysicalRect, newer)
    }

    func testFloatingFrameReturnsExactlyIncludingPartialOffscreenPlacement() {
        let monitor = Rect(topLeftX: -1440, topLeftY: 0, width: 1440, height: 900)
        var rect = Rect(topLeftX: -1452.25, topLeftY: 730.75, width: 801.5, height: 601.25)
        let original = rect
        for _ in 0..<100 {
            rect = WindowParkingSnapshot(frame: rect, monitorRect: monitor).restoredFrame(on: monitor)
        }
        XCTAssertEqual(rect, original, "Switching groups must not clamp or accumulate proportional rounding")
    }

    func testFloatingFrameMapsAndClampsOnlyWhenMonitorChanges() {
        let source = Rect(topLeftX: -1440, topLeftY: 0, width: 1440, height: 900)
        let target = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        let frame = Rect(topLeftX: -360, topLeftY: 675, width: 800, height: 600)
        let restored = WindowParkingSnapshot(frame: frame, monitorRect: source).restoredFrame(on: target)
        XCTAssertEqual(restored, Rect(topLeftX: 1120, topLeftY: 480, width: 800, height: 600))
    }

    func testParkedTilingToFloatingConversionKeepsCommandSelectedSize() async throws {
        let monitor = focus.workspace.workspaceMonitor.rect
        let tiled = Rect(topLeftX: 44, topLeftY: 28, width: 800, height: 600)
        let converted = Rect(topLeftX: monitor.maxX - 1, topLeftY: monitor.maxY - 1, width: 500, height: 400)
        let window = TestWindow.new(id: 909, parent: focus.workspace, rect: converted)
        window.restoreFloatingFrame(.init(frame: tiled, monitorRect: monitor), on: monitor, restoreSize: false)
        let actual = try await window.getAxRect()
        XCTAssertEqual(actual?.topLeftCorner, tiled.topLeftCorner)
        XCTAssertEqual(actual?.size, converted.size)
    }

    func testFloatingLayoutDoesNotRelocateJustRestoredCrossMonitorWindow() async throws {
        let left = Rect(topLeftX: -1440, topLeftY: 0, width: 1440, height: 900)
        let right = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        let source = TestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Left", rect: left, visibleRect: left, isMain: true)
        let other = TestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Right", rect: right, visibleRect: right, isMain: false)
        setMonitorsForTests([source, other])
        defer { setMonitorsForTests(nil) }
        let workspace = Workspace.get(byName: "cross-monitor-floating")
        XCTAssertTrue(source.setActiveWorkspace(workspace))
        let rect = Rect(topLeftX: -100, topLeftY: 500, width: 800, height: 600)
        let window = TestWindow.new(id: 908, parent: workspace, rect: rect)
        window.restoreFloatingFrame(.init(frame: rect, monitorRect: left), on: left)
        let writes = window.frameWriteCount
        try await workspace.layoutWorkspace()
        XCTAssertEqual(window.frameWriteCount, writes)
        let actual = try await window.getAxRect()
        XCTAssertEqual(actual, rect)
        XCTAssertNil(window.restoredFloatingFrameMonitorRect)
    }
}
