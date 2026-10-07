@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor
final class SurfaceClosureFocusTest: XCTestCase {
    private var controller: BrowserWorkspaceController!
    private var connection: UUID!
    private var epoch: UUID!
    private var pages: [SurfaceID] = []
    private var revision: UInt64 = 0

    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.newItemPlacement = .tile
        controller = BrowserWorkspaceController(foregroundProcessID: { -1 })
        controller.usesSurfaceTree = true
        connection = UUID(); epoch = UUID(); revision = 0
        let profile = UUID()
        pages = (0..<4).map { _ in .browserTab(profile: profile, tab: UUID()) }
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        inventory(pages)
    }

    override func tearDown() async throws { controller.disconnected(connection) }

    func testBrowserCloseWalksVisitHistoryInsteadOfTabOrderOrEngineFallback() {
        let first = pages[0], second = pages[1], third = pages[2], adjacent = pages[3]
        for id in [second, first, third] { XCTAssertEqual(controller.select(id), .issued) }
        controller.cancelPendingBrowserFocusHold()

        inventory([first, second, adjacent], focused: adjacent)
        XCTAssertEqual(controller.focusCoordinator.target, first)
        inventory([second, adjacent], focused: adjacent)
        XCTAssertEqual(controller.focusCoordinator.target, second)
    }

    func testBrowserCloseReturnsToNativeAppInPreviousView() {
        config.newItemPlacement = .newView
        let previous = Workspace.get(byName: "Previous app")
        let native = TestWindow.new(id: 811, parent: previous.rootTilingContainer)
        XCTAssertEqual(controller.select(native.surfaceID), .issued)
        XCTAssertEqual(controller.select(pages[0]), .issued)

        inventory(Array(pages.dropFirst()), focused: pages[1])
        XCTAssertEqual(controller.focusCoordinator.target, native.surfaceID)
        XCTAssertEqual(focus.workspace, previous)
        XCTAssertEqual(focus.windowOrNil, native)
        XCTAssertTrue(controller.finishNativeGroupFocusAfterLayout())
        XCTAssertEqual(TestApp.shared.focusedWindow, native)
    }

    func testNativeClosureUsesPreRefreshHistoryToReturnToBrowser() {
        let nativeWorkspace = Workspace.get(byName: "Native view")
        let native = TestWindow.new(id: 812, parent: nativeWorkspace.rootTilingContainer)
        let provisional = TestWindow.new(id: 813, parent: nativeWorkspace.rootTilingContainer)
        XCTAssertEqual(controller.select(pages[2]), .issued)
        XCTAssertEqual(controller.select(native.surfaceID), .issued)
        let snapshot = controller.captureClosureFocus()
        // AX can report the app's own replacement before destruction is seen.
        controller.nativeSelectionChanged(provisional.surfaceID)
        native.unbindFromParent()

        XCTAssertTrue(controller.restoreFocusAfterClosing([native.surfaceID], snapshot: snapshot, workspace: nativeWorkspace))
        XCTAssertEqual(controller.focusCoordinator.target, pages[2])
    }

    func testClosingBackgroundBrowserTabPreservesSelectionAndHistory() {
        XCTAssertEqual(controller.select(pages[1]), .issued)
        XCTAssertEqual(controller.select(pages[2]), .issued)
        inventory(Array(pages.dropFirst()))
        XCTAssertEqual(controller.focusCoordinator.target, pages[2])
        XCTAssertEqual(Array(controller.recentSelections.prefix(2)), [pages[2], pages[1]])
    }

    func testClosingBackgroundNativeWindowDoesNotRestoreAnOlderSelection() {
        let native = TestWindow.new(id: 814, parent: focus.workspace.rootTilingContainer)
        XCTAssertEqual(controller.select(native.surfaceID), .issued)
        XCTAssertEqual(controller.select(pages[1]), .issued)
        let snapshot = controller.captureClosureFocus()
        native.unbindFromParent()
        XCTAssertFalse(controller.restoreFocusAfterClosing([native.surfaceID], snapshot: snapshot, workspace: focus.workspace))
        XCTAssertEqual(controller.focusCoordinator.target, pages[1])
    }

    func testCloseRequestWaitsForRemovalAndRespectsInterveningSelection() {
        XCTAssertEqual(controller.select(pages[0]), .issued)
        XCTAssertEqual(controller.select(pages[1]), .issued)
        XCTAssertEqual(controller.close(pages[1]), .issued)
        XCTAssertEqual(controller.focusCoordinator.target, pages[1], "A close request may still be cancelled")
        XCTAssertEqual(controller.select(pages[2]), .issued)
        inventory([pages[0], pages[2], pages[3]])
        XCTAssertEqual(controller.focusCoordinator.target, pages[2])
    }

    func testHistorySkipsMissingMinimizedAndArchivedSurfaces() {
        let native = TestWindow.new(id: 815, parent: focus.workspace.rootTilingContainer)
        let hidden = TestWindow.new(id: 816, parent: focus.workspace.rootTilingContainer)
        let archived = Workspace.get(byName: "Archived")
        let archivedWindow = TestWindow.new(id: 817, parent: archived.rootTilingContainer)
        for id in [pages[0], native.surfaceID, hidden.surfaceID, archivedWindow.surfaceID, pages[1]] {
            XCTAssertEqual(controller.select(id), .issued)
        }
        native.unbindFromParent()
        hidden.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        archived.lifecycle = .archived
        inventory([pages[0], pages[2], pages[3]])
        XCTAssertEqual(controller.focusCoordinator.target, pages[0])
    }

    func testBatchRemovalSkipsEveryClosedTabAndLastCloseClearsTarget() {
        for id in pages { XCTAssertEqual(controller.select(id), .issued) }
        inventory([pages[0]])
        XCTAssertEqual(controller.focusCoordinator.target, pages[0])
        inventory([])
        XCTAssertNil(controller.focusCoordinator.target)
        XCTAssertTrue(controller.recentSelections.isEmpty)
    }

    private func inventory(_ ids: [SurfaceID], focused: SurfaceID? = nil) {
        revision += 1
        controller.received(.init(revision: revision, full: true, tabs: ids.map {
            .init(surfaceID: $0, hostID: $0.description, title: "Page", selected: true, focused: $0 == focused)
        }), epoch: epoch, connection: connection, protocolVersion: 4)
    }
}
