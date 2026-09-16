@testable import AppBundle
import Common
import XCTest

@MainActor
final class TrackpadNavigationTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func group() -> [Window] {
        let container = TilingContainer(parent: Workspace.get(byName: name).rootTilingContainer,
            adaptiveWeight: 1, .h, .tabGroup, index: INDEX_BIND_LAST)
        let windows = (1...3).map { TestWindow.new(id: UInt32($0), parent: container) }
        _ = windows[0].focusWindow()
        return windows
    }

    func testTargetUsesTabOrderWrappingAndReverseDirection() throws {
        let windows = group()
        let target = try XCTUnwrap(TrackpadTabTarget.capture())
        XCTAssertEqual(target.resolve(direction: .left, reversed: false)?.destination.windowId, windows[1].windowId)
        XCTAssertEqual(target.resolve(direction: .right, reversed: false)?.destination.windowId, windows[2].windowId)
        XCTAssertEqual(target.resolve(direction: .left, reversed: true)?.destination.windowId, windows[2].windowId)
        XCTAssertEqual(target.resolve(direction: .right, reversed: true)?.destination.windowId, windows[1].windowId)
    }

    func testTargetRejectsFocusAndMembershipChanges() throws {
        let windows = group()
        let target = try XCTUnwrap(TrackpadTabTarget.capture())
        _ = windows[1].focusWindow()
        XCTAssertNil(target.resolve(direction: .left, reversed: false))
        _ = windows[0].focusWindow()
        _ = TestWindow.new(id: 4, parent: windows[0].parent!)
        XCTAssertNil(target.resolve(direction: .left, reversed: false))
    }

    func testNoTargetOutsideGroupOrWithSingleTab() {
        let root = Workspace.get(byName: name).rootTilingContainer
        _ = TestWindow.new(id: 1, parent: root).focusWindow()
        XCTAssertNil(TrackpadTabTarget.capture())
        let container = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tabGroup, index: INDEX_BIND_LAST)
        _ = TestWindow.new(id: 2, parent: container).focusWindow()
        XCTAssertNil(TrackpadTabTarget.capture())
    }

    func testLifecycleAndStaleCallbacks() async {
        _ = group()
        let backend = FakeTrackpadBackend()
        var activations = 0
        let controller = TrackpadNavigationController(backend: backend, nativeFocusMatches: { _ in true }, activate: { _, _ in activations += 1 })
        controller.update(configuration: .init(enabled: false), isActive: true)
        XCTAssertEqual(backend.starts, 0)
        controller.update(configuration: .init(enabled: true), isActive: true)
        XCTAssertEqual(controller.status, .ready(1))
        controller.update(configuration: .init(enabled: true), isActive: true)
        XCTAssertEqual(backend.starts, 1)
        backend.send([.began(1), .committed(1, .left), .ended(1)])
        await drainMainQueue()
        XCTAssertEqual(activations, 1)
        controller.update(configuration: .init(enabled: true), isActive: false)
        XCTAssertEqual(controller.status, .paused)
        XCTAssertEqual(backend.stops, 1)
        controller.update(configuration: .init(enabled: true), isActive: true)
        backend.send([.began(1), .committed(1, .left)], subscription: 0)
        await drainMainQueue()
        XCTAssertEqual(activations, 1)
        controller.shutdown()
    }

    func testCancellationNativeFocusMismatchAndOldEventsNeverNavigate() async {
        _ = group()
        let backend = FakeTrackpadBackend()
        var activations = 0
        var matches = false
        let controller = TrackpadNavigationController(backend: backend, nativeFocusMatches: { _ in matches }, activate: { _, _ in activations += 1 })
        controller.update(configuration: .init(enabled: true), isActive: true)
        backend.send([.began(1), .committed(1, .left)])
        await drainMainQueue()
        XCTAssertEqual(activations, 0)
        matches = true
        backend.send([.ended(1), .began(1)])
        await drainMainQueue()
        controller.cancelCandidate()
        backend.send([.committed(1, .left), .ended(1)])
        await drainMainQueue()
        XCTAssertEqual(activations, 0)
        XCTAssertTrue(controller.ownedDevices.isEmpty)
        backend.send([.began(1), .committed(1, .left), .ended(1)], receivedAt: ProcessInfo.processInfo.systemUptime - 1)
        await drainMainQueue()
        XCTAssertEqual(activations, 0)
        controller.shutdown()
    }

    func testBackendFailureAndUnavailableDeviceStatus() async {
        let backend = FakeTrackpadBackend()
        backend.result = .unavailable
        let controller = TrackpadNavigationController(backend: backend)
        controller.update(configuration: .init(enabled: true), isActive: true)
        XCTAssertEqual(controller.status, .unavailable)
        controller.update(configuration: .init(enabled: false), isActive: true)
        backend.result = .listening(0)
        controller.update(configuration: .init(enabled: true), isActive: true)
        XCTAssertEqual(controller.status, .noTrackpad)
        backend.failures.last?()
        await drainMainQueue()
        XCTAssertEqual(controller.status, .invalidInput)
        let starts = backend.starts
        controller.update(configuration: .init(enabled: true), isActive: true)
        XCTAssertEqual(backend.starts, starts)
        controller.update(configuration: .init(enabled: false), isActive: true)
        backend.result = .listening(1)
        controller.update(configuration: .init(enabled: true), isActive: true)
        XCTAssertEqual(controller.status, .ready(1))
        controller.shutdown()
    }

    func testSidebarSuppressesOnlyOwnedSequenceIncludingMomentum() {
        var gate = TrackpadSidebarScrollGate()
        XCTAssertFalse(gate.shouldSuppress(owned: false, phase: .began, momentum: []))
        XCTAssertTrue(gate.shouldSuppress(owned: true, phase: .changed, momentum: []))
        XCTAssertTrue(gate.shouldSuppress(owned: false, phase: .ended, momentum: []))
        XCTAssertTrue(gate.shouldSuppress(owned: false, phase: [], momentum: .began))
        XCTAssertTrue(gate.shouldSuppress(owned: false, phase: [], momentum: .ended))
        XCTAssertFalse(gate.shouldSuppress(owned: false, phase: .began, momentum: []))
    }

    private func drainMainQueue() async { try? await Task.sleep(for: .milliseconds(20)) }
}

@MainActor
private final class FakeTrackpadBackend: TrackpadInputBackend {
    var result: TrackpadBackendStatus = .listening(1)
    var starts = 0
    var stops = 0
    var subscriptions: [@Sendable ([TrackpadGestureEvent], Double) -> Void] = []
    var failures: [@Sendable () -> Void] = []

    func start(deliver: @escaping @Sendable ([TrackpadGestureEvent], Double) -> Void,
               invalidInput: @escaping @Sendable () -> Void) -> TrackpadBackendStatus {
        starts += 1
        subscriptions.append(deliver)
        failures.append(invalidInput)
        return result
    }
    func stop() { stops += 1 }
    func send(_ events: [TrackpadGestureEvent], subscription: Int? = nil, receivedAt: Double = ProcessInfo.processInfo.systemUptime) {
        subscriptions[subscription ?? subscriptions.count - 1](events, receivedAt)
    }
}
