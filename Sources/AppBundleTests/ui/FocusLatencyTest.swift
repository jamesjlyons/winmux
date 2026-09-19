@testable import AppBundle
import AppKit
import Combine
import Common
import XCTest

@MainActor
final class FocusLatencyTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        TrayMenuModel.shared.isEnabled = true
        appForTests = nil
    }

    func testFullscreenChromeReadBenchmark() async {
        let window = FocusLatencyWindow(id: 1, parent: focus.workspace.rootTilingContainer)
        window.fullscreenDelay = .milliseconds(2)
        let start = ContinuousClock.now
        for _ in 0 ..< 20 { await updateNativeFullscreenChromeSuppression(nativeFocused: window) }
        print("FOCUS_LATENCY_BENCHMARK fullscreen_reads=\(window.fullscreenReads) elapsed=\(start.duration(to: .now))")
        XCTAssertFalse(shouldSuppressChromeForNativeFullscreenContent)
        XCTAssertEqual(window.fullscreenReads, 1)
    }

    func testExplicitFocusGeometryBenchmark() async throws {
        let workspace = focus.workspace
        let target = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let floats = (2 ... 5).map { id in
            let window = FocusLatencyWindow(id: UInt32(id), parent: workspace)
            window.geometryDelay = .milliseconds(2)
            return window
        }
        let start = ContinuousClock.now
        for _ in 0 ..< 10 {
            let result = try await FocusCommand(args: .init(rawArgs: [], windowId: target.windowId)).run(.defaultEnv, .emptyStdin)
            XCTAssertEqual(result.exitCode, 0)
        }
        print("FOCUS_LATENCY_BENCHMARK explicit_focus_geometry_reads=\(floats.reduce(0) { $0 + $1.geometryReads }) elapsed=\(start.duration(to: .now))")
        XCTAssertTrue(focus.windowOrNil === target)
        XCTAssertTrue(floats.allSatisfy { $0.parent === workspace })
        XCTAssertEqual(floats.reduce(0) { $0 + $1.geometryReads }, 0)
    }

    func testFullscreenCacheInvalidatesAndDoesNotInventMinimizedState() async {
        let window = FocusLatencyWindow(id: 1, parent: focus.workspace.rootTilingContainer)
        await updateNativeFullscreenChromeSuppression(nativeFocused: window)
        await updateNativeFullscreenChromeSuppression(nativeFocused: window)
        XCTAssertEqual(window.fullscreenReads, 1)
        XCTAssertEqual(window.lastKnownNativeFullscreen, false)
        XCTAssertNil(window.lastKnownNativeMinimized)
        window.fullscreen = true
        window.invalidateLastKnownNativeState()
        await updateNativeFullscreenChromeSuppression(nativeFocused: window)
        XCTAssertEqual(window.fullscreenReads, 2)
        XCTAssertTrue(shouldSuppressChromeForNativeFullscreenContent)
        window.fullscreen = false
        window.invalidateLastKnownNativeState()
        await updateNativeFullscreenChromeSuppression(nativeFocused: window)
        XCTAssertEqual(window.fullscreenReads, 3)
        XCTAssertFalse(shouldSuppressChromeForNativeFullscreenContent)
    }

    func testFullscreenCacheReusesNormalizationAndNilFocusClearsChrome() async {
        let window = FocusLatencyWindow(id: 1, parent: focus.workspace.rootTilingContainer)
        window.recordObservedNativeState(fullscreen: true, minimized: false, token: window.nativeStateObservationToken())
        await updateNativeFullscreenChromeSuppression(nativeFocused: window)
        XCTAssertTrue(shouldSuppressChromeForNativeFullscreenContent)
        XCTAssertEqual(window.fullscreenReads, 0)
        await updateNativeFullscreenChromeSuppression(nativeFocused: nil)
        XCTAssertFalse(shouldSuppressChromeForNativeFullscreenContent)
    }

    func testInvalidatedFullscreenObservationDoesNotOverwriteCurrentChrome() async throws {
        let window = FocusLatencyWindow(id: 1, parent: focus.workspace.rootTilingContainer)
        shouldSuppressChromeForNativeFullscreenContent = true
        let started = expectation(description: "Fullscreen read started")
        var continuation: CheckedContinuation<Bool, Never>?
        window.readFullscreen = {
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        }
        let old = Task { await updateNativeFullscreenChromeSuppression(nativeFocused: window) }
        await fulfillment(of: [started], timeout: 1)
        window.invalidateLastKnownNativeState()
        try XCTUnwrap(continuation).resume(returning: false)
        await old.value
        XCTAssertTrue(shouldSuppressChromeForNativeFullscreenContent)
        XCTAssertNil(window.lastKnownNativeFullscreen)
    }

    func testNewerFocusWinsOverSuspendedFullscreenLookup() async throws {
        let window = FocusLatencyWindow(id: 1, parent: focus.workspace.rootTilingContainer)
        let started = expectation(description: "Old focus read started")
        var continuation: CheckedContinuation<Bool, Never>?
        window.readFullscreen = {
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        }
        let old = Task { await updateNativeFullscreenChromeSuppression(nativeFocused: window) }
        await fulfillment(of: [started], timeout: 1)
        await updateNativeFullscreenChromeSuppression(nativeFocused: nil)
        try XCTUnwrap(continuation).resume(returning: true)
        await old.value
        XCTAssertFalse(shouldSuppressChromeForNativeFullscreenContent)
        XCTAssertNil(window.lastKnownNativeFullscreen)
    }

    func testFailedFullscreenReadRemainsRetryable() async {
        let window = FocusLatencyWindow(id: 1, parent: focus.workspace.rootTilingContainer)
        window.readFullscreen = { throw NSError(domain: "FocusLatencyTest", code: 1) }
        await updateNativeFullscreenChromeSuppression(nativeFocused: window)
        XCTAssertNil(window.lastKnownNativeFullscreen)
        XCTAssertFalse(shouldSuppressChromeForNativeFullscreenContent)
        window.readFullscreen = nil
        window.fullscreen = true
        await updateNativeFullscreenChromeSuppression(nativeFocused: window)
        XCTAssertTrue(shouldSuppressChromeForNativeFullscreenContent)
        XCTAssertEqual(window.fullscreenReads, 2)
    }

    func testNativeFocusIsRequestedAfterLayoutBeforeSidebarPublication() async throws {
        let first = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let target = FocusLatencyWindow(id: 2, parent: focus.workspace.rootTilingContainer)
        XCTAssertTrue(first.focusWindow())
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = first
        config.workspaceSidebar.enabled = true
        TrayMenuModel.shared.workspaceSidebarWorkspaces = []
        var published = false
        target.onFocus = { XCTAssertGreaterThan(target.frameWrites, 0) }
        let subscription = TrayMenuModel.shared.$workspaceSidebarWorkspaces.dropFirst().sink { workspaces in
            guard !workspaces.isEmpty else { return }
            published = true
            XCTAssertEqual(target.focusRequests, 1)
        }
        defer {
            subscription.cancel()
            target.onFocus = nil
        }
        try await runLightSession(.hotkeyBinding, .forceRun, shouldSchedulePostRefresh: false) {
            XCTAssertTrue(target.focusWindow())
        }
        XCTAssertTrue(published)
        XCTAssertEqual(target.focusRequests, 1)
    }

    func testUnchangedOrCancelledFocusDoesNotRequestNativeFocus() async throws {
        let window = FocusLatencyWindow(id: 1, parent: focus.workspace.rootTilingContainer)
        XCTAssertTrue(window.focusWindow())
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = window
        try await runLightSession(.hotkeyBinding, .forceRun, shouldSchedulePostRefresh: false) {}
        XCTAssertEqual(window.focusRequests, 0)
        let target = FocusLatencyWindow(id: 2, parent: focus.workspace.rootTilingContainer)
        do {
            try await runLightSession(.hotkeyBinding, .forceRun, shouldSchedulePostRefresh: false) {
                XCTAssertTrue(target.focusWindow())
                throw CancellationError()
            }
            XCTFail("Cancellation should propagate")
        } catch is CancellationError {}
        XCTAssertEqual(target.focusRequests, 0)
        XCTAssertEqual(target.frameWrites, 0)
    }

    func testExplicitFloatingTargetKeepsItsParentAndAvoidsGeometryReads() async throws {
        let workspace = focus.workspace
        let target = FocusLatencyWindow(id: 1, parent: workspace)
        let neighbor = FocusLatencyWindow(id: 2, parent: workspace)
        _ = workspace.rootTilingContainer
        let children = workspace.children
        let result = try await FocusCommand(args: .init(rawArgs: [], windowId: target.windowId)).run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(focus.windowOrNil === target)
        XCTAssertEqual(workspace.children, children)
        XCTAssertEqual(target.geometryReads + neighbor.geometryReads, 0)
    }
}

private final class FocusLatencyWindow: Window {
    var fullscreenReads = 0
    var geometryReads = 0
    var focusRequests = 0
    var frameWrites = 0
    var fullscreen = false
    var fullscreenDelay: Duration = .zero
    var geometryDelay: Duration = .zero
    var readFullscreen: (@MainActor () async throws -> Bool)?
    var onFocus: (@MainActor () -> Void)?

    @MainActor init(id: UInt32, parent: NonLeafTreeNodeObject) {
        super.init(id: id, TestApp.shared, lastFloatingSize: nil, parent: parent, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        TestApp.shared._windows.append(self)
    }

    override var title: String { get async { "Focus probe" } }
    override var isHiddenInCorner: Bool { false }
    @MainActor override var isMacosFullscreen: Bool {
        get async throws {
            fullscreenReads += 1
            if fullscreenDelay != .zero { try await Task.sleep(for: fullscreenDelay) }
            if let readFullscreen { return try await readFullscreen() }
            return fullscreen
        }
    }
    @MainActor override func getAxRect() async throws -> Rect? {
        geometryReads += 1
        if geometryDelay != .zero { try await Task.sleep(for: geometryDelay) }
        return Rect(topLeftX: 100, topLeftY: 100, width: 200, height: 200)
    }
    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) { frameWrites += 1 }
    @MainActor override func nativeFocus() {
        focusRequests += 1
        TestApp.shared.focusedWindow = self
        onFocus?()
    }
}
