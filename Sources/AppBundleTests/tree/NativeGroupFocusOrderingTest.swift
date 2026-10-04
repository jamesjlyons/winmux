@testable import AppBundle
import WorkspaceCore
import XCTest

@MainActor
final class NativeGroupFocusOrderingTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testHiddenNativeRowAutomaticallyWaitsForPlacement() {
        let controller = BrowserWorkspaceController(foregroundProcessID: { -1 })
        let hidden = Workspace.get(byName: "hidden-native-row")
        let window = TestWindow.new(id: 955, parent: hidden.rootTilingContainer)
        XCTAssertFalse(hidden.isVisible)
        XCTAssertEqual(controller.select(window.surfaceID), .issued)
        XCTAssertTrue(hidden.isVisible)
        XCTAssertNil(TestApp.shared.focusedWindow)
        XCTAssertTrue(controller.finishNativeGroupFocusAfterLayout())
        XCTAssertTrue(TestApp.shared.focusedWindow === window)
    }

    func testVisibleNativeRowRetainsImmediateFocus() {
        let controller = BrowserWorkspaceController(foregroundProcessID: { -1 })
        let window = TestWindow.new(id: 956, parent: focus.workspace.rootTilingContainer)
        XCTAssertEqual(controller.select(window.surfaceID), .issued)
        XCTAssertTrue(TestApp.shared.focusedWindow === window)
        XCTAssertFalse(controller.finishNativeGroupFocusAfterLayout())
    }

    func testImmediateBrowserFenceCannotRaiseDeferredNativeGroup() throws {
        let controller = BrowserWorkspaceController(foregroundProcessID: { -1 })
        let window = TestWindow.new(id: 951, parent: focus.workspace.rootTilingContainer)
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID()), connection = UUID()
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [.init(surfaceID: page, hostID: "test", title: "Page", selected: true)]),
                            epoch: UUID(), connection: connection, protocolVersion: 4)
        XCTAssertEqual(controller.select(window.surfaceID, deferNativeFocusUntilLayout: true), .issued)
        XCTAssertNil(TestApp.shared.focusedWindow)
        XCTAssertTrue(controller.finishNativeGroupFocusAfterLayout())
        XCTAssertTrue(TestApp.shared.focusedWindow === window)
        XCTAssertFalse(controller.finishNativeGroupFocusAfterLayout())
    }

    func testRapidNativeBrowserNativeIntentOnlyRaisesLatestTarget() {
        let controller = BrowserWorkspaceController(foregroundProcessID: { -1 })
        let first = TestWindow.new(id: 952, parent: focus.workspace.rootTilingContainer)
        let second = TestWindow.new(id: 953, parent: focus.workspace.rootTilingContainer)
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID()), connection = UUID()
        var replies: [@MainActor (BrowserActionReply) -> Void] = []
        controller.connected(connection, processID: -1) { _, reply in replies.append(reply) }
        controller.received(.init(revision: 1, full: true, tabs: [.init(surfaceID: page, hostID: "test", title: "Page", selected: true)]),
                            epoch: UUID(), connection: connection, protocolVersion: 4)
        XCTAssertEqual(controller.select(first.surfaceID, deferNativeFocusUntilLayout: true), .issued)
        XCTAssertEqual(controller.select(page), .issued)
        XCTAssertEqual(controller.select(second.surfaceID, deferNativeFocusUntilLayout: true), .issued)
        for reply in replies { reply(.issued) }
        XCTAssertNil(TestApp.shared.focusedWindow)
        XCTAssertTrue(controller.finishNativeGroupFocusAfterLayout())
        XCTAssertTrue(TestApp.shared.focusedWindow === second)
    }

    func testInterveningAppActivationRetiresDeferredTargetAndLateFence() {
        var foreground: Int32? = -1
        let controller = BrowserWorkspaceController(foregroundProcessID: { foreground })
        let window = TestWindow.new(id: 954, parent: focus.workspace.rootTilingContainer)
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID()), connection = UUID()
        var replies: [@MainActor (BrowserActionReply) -> Void] = []
        controller.connected(connection, processID: -1) { _, reply in replies.append(reply) }
        controller.received(.init(revision: 1, full: true, tabs: [.init(surfaceID: page, hostID: "test", title: "Page", selected: true)]),
                            epoch: UUID(), connection: connection, protocolVersion: 4)
        XCTAssertEqual(controller.select(window.surfaceID, deferNativeFocusUntilLayout: true), .issued)
        foreground = -2
        XCTAssertTrue(controller.finishNativeGroupFocusAfterLayout())
        XCTAssertNil(TestApp.shared.focusedWindow)
        XCTAssertNil(controller.focusCoordinator.target)
        for reply in replies { reply(.issued) }
        XCTAssertNil(TestApp.shared.focusedWindow)
    }
}
