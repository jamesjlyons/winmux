@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor
final class BrowserGroupSwitchTest: XCTestCase {
    private let controller = BrowserWorkspaceController.shared
    private var connection = UUID(), epoch = UUID()
    private var requests: [BrowserActionRequest] = []
    private var previousEnabled = true
    private var firstPage = SurfaceID.browserTab(profile: UUID(), tab: UUID())
    private var secondPage = SurfaceID.browserTab(profile: UUID(), tab: UUID())
    private var mixedPage = SurfaceID.browserTab(profile: UUID(), tab: UUID())
    private var source: Workspace!
    private var browserGroup: Workspace!
    private var mixedGroup: Workspace!
    private var sourceWindow: TestWindow!
    private var mixedWindow: TestWindow!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        previousEnabled = TrayMenuModel.shared.isEnabled
        TrayMenuModel.shared.isEnabled = true
        connection = UUID(); epoch = UUID(); requests = []
        let profile = UUID()
        firstPage = .browserTab(profile: profile, tab: UUID())
        secondPage = .browserTab(profile: profile, tab: UUID())
        mixedPage = .browserTab(profile: profile, tab: UUID())
        source = focus.workspace
        browserGroup = Workspace.get(byName: "Browser-group")
        mixedGroup = Workspace.get(byName: "Mixed-group")
        sourceWindow = TestWindow.new(id: 801, parent: source.rootTilingContainer)
        mixedWindow = TestWindow.new(id: 802, parent: mixedGroup.rootTilingContainer)
        XCTAssertTrue(sourceWindow.focusWindow())
        sourceWindow.nativeFocus()
        var tree = SurfaceTree()
        tree.reconcile([sourceWindow.surfaceID], in: source.name)
        tree.reconcile([firstPage, secondPage], in: browserGroup.name)
        tree.reconcile([mixedWindow.surfaceID, mixedPage], in: mixedGroup.name)
        controller.restorePlacementSnapshot(.init(tree: tree,
            layoutWorkspaces: [source.name, browserGroup.name, mixedGroup.name], selected: nil, closedBrowserTabs: []))
        controller.connected(connection, processID: -1) { [weak self] request, reply in
            self?.requests.append(request)
            reply(.issued)
        }
        controller.received(.init(revision: 1, full: true, tabs: [record(firstPage), record(secondPage), record(mixedPage)]),
                            epoch: epoch, connection: connection, protocolVersion: 4)
    }

    override func tearDown() async throws {
        controller.disconnected(connection)
        controller.nativeSelectionChanged(nil)
        controller.restorePlacementSnapshot(.init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        controller.usesSurfaceTree = false
        TrayMenuModel.shared.isEnabled = previousEnabled
        appForTests = nil
    }

    private func record(_ id: SurfaceID, focused: Bool = false) -> BrowserTabRecord {
        .init(surfaceID: id, hostID: id.description, title: "Synthetic page", selected: true,
              hostMinimumSize: .init(width: 500, height: 300), hostManaged: true, focused: focused)
    }

    func testSidebarGroupHeaderSelectsAnAvailableBrowserPage() async throws {
        XCTAssertTrue(controller.usesSurfaceTree)
        XCTAssertTrue(browserGroup.allLeafWindowsRecursive.isEmpty)
        requests = []
        try await runLightSession(.menuBarButton, .forceRun, shouldSchedulePostRefresh: false) {
            XCTAssertTrue(focusWorkspaceFromSidebar(self.browserGroup))
        }
        XCTAssertTrue(focus.workspace === browserGroup)
        let selected = try XCTUnwrap(controller.focusCoordinator.target)
        XCTAssertTrue([firstPage, secondPage].contains(selected))
        XCTAssertEqual(requests.last(where: { $0.action == .focus })?.surfaceID, selected)
        let placement = try XCTUnwrap(controller.plannedSurfaces(in: browserGroup).first { $0.surfaceID == selected })
        XCTAssertTrue(placement.visible)
        XCTAssertTrue(controller.plannedSurfaces(in: source).allSatisfy { !$0.visible })
    }

    func testWorkspaceCommandSelectsBrowserOnlyDestination() async throws {
        let command = try XCTUnwrap(parseCommand(["workspace", browserGroup.name]).cmdOrNil)
        let result = try await command.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode, 0, result.stderr.joined())
        XCTAssertTrue(focus.workspace === browserGroup)
        let selected = try XCTUnwrap(controller.focusCoordinator.target)
        XCTAssertEqual(controller.workspaceName(for: selected), browserGroup.name)
        XCTAssertTrue(controller.hasBrowserSelection)
        XCTAssertEqual(requests.last(where: { $0.action == .focus })?.surfaceID, selected)
    }

    func testReturningToMixedGroupRestoresBrowserSelectionWithoutNativeFocusOverride() async throws {
        XCTAssertEqual(controller.select(mixedPage), .issued)
        XCTAssertTrue(source.focusWorkspace())
        sourceWindow.nativeFocus()
        requests = []
        try await runLightSession(.menuBarButton, .forceRun, shouldSchedulePostRefresh: false) {
            XCTAssertTrue(focusWorkspaceFromSidebar(self.mixedGroup))
        }
        XCTAssertTrue(focus.workspace === mixedGroup)
        XCTAssertEqual(controller.focusCoordinator.target, mixedPage)
        XCTAssertEqual(requests.last(where: { $0.action == .focus })?.surfaceID, mixedPage)
        XCTAssertFalse(TestApp.shared.focusedWindow === mixedWindow,
                       "The native layout synchronization must not override the restored browser page")
    }

    func testReturningToMixedGroupRestoresItsNativeSelection() {
        XCTAssertEqual(controller.select(mixedPage), .issued)
        XCTAssertEqual(controller.select(mixedWindow.surfaceID), .issued)
        XCTAssertTrue(source.focusWorkspace())
        sourceWindow.nativeFocus()
        XCTAssertTrue(focusWorkspaceFromSidebar(mixedGroup))
        XCTAssertTrue(focus.workspace === mixedGroup)
        XCTAssertEqual(controller.focusCoordinator.target, mixedWindow.surfaceID)
        XCTAssertTrue(TestApp.shared.focusedWindow === mixedWindow)
    }

    func testReturningToBrowserOnlyGroupRemembersItsLastPage() {
        XCTAssertEqual(controller.select(secondPage), .issued)
        XCTAssertTrue(source.focusWorkspace())
        XCTAssertTrue(browserGroup.focusWorkspace())
        XCTAssertEqual(controller.focusCoordinator.target, secondPage)
        XCTAssertTrue(focus.workspace === browserGroup)
    }

    func testStartupGroupActivationPreservesDeferredBrowserSelection() {
        let previousRuntimeReady = isWinMuxRuntimeReady
        isWinMuxRuntimeReady = false
        defer { isWinMuxRuntimeReady = previousRuntimeReady }
        controller.restorePlacementSnapshot(.init(tree: controller.surfaceTree,
            layoutWorkspaces: [source.name, browserGroup.name, mixedGroup.name],
            selected: secondPage, closedBrowserTabs: []))
        XCTAssertTrue(controller.isAvailable(sourceWindow.surfaceID))
        XCTAssertTrue(controller.isAvailable(secondPage))

        // Startup activates its initial native group before deferred browser
        // restoration runs. That fallback must preserve the saved browser page.
        XCTAssertTrue(source.focusWorkspace())
        XCTAssertEqual(controller.capturePlacementSnapshot()?.selected, secondPage)

        // An explicit selection consumes the deferred restoration, so the next
        // native selection is recorded even while startup remains in progress.
        XCTAssertEqual(controller.select(secondPage), .issued)
        controller.nativeSelectionChanged(sourceWindow.surfaceID)
        XCTAssertEqual(controller.capturePlacementSnapshot()?.selected, sourceWindow.surfaceID)
    }

    func testEmptyGroupClearsBrowserSelection() {
        XCTAssertEqual(controller.select(firstPage), .issued)
        let empty = Workspace.get(byName: "Empty-group")
        XCTAssertTrue(empty.focusWorkspace())
        XCTAssertTrue(focus.workspace === empty)
        XCTAssertNil(controller.focusCoordinator.target)
        XCTAssertFalse(controller.hasBrowserSelection)
        XCTAssertTrue(controller.plannedSurfaces(in: browserGroup).allSatisfy { !$0.visible })
    }

    func testRemovedBrowserSelectionFallsBackToRemainingAvailablePage() {
        XCTAssertEqual(controller.select(secondPage), .issued)
        XCTAssertTrue(source.focusWorkspace())
        controller.received(.init(revision: 2, full: false, tabs: [], removed: [secondPage]),
                            epoch: epoch, connection: connection, protocolVersion: 4)
        XCTAssertFalse(controller.isAvailable(secondPage))
        XCTAssertTrue(browserGroup.focusWorkspace())
        XCTAssertEqual(controller.focusCoordinator.target, firstPage)
        XCTAssertTrue(focus.workspace === browserGroup)
        XCTAssertTrue(controller.isAvailable(firstPage))
    }

    func testHiddenGroupFocusedInventoryCannotReplaceCurrentBrowserSelection() {
        let local = BrowserWorkspaceController(foregroundProcessID: { -1 })
        let localConnection = UUID(), localEpoch = UUID()
        let old = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let current = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let oldGroup = Workspace.get(byName: "Old-browser-group")
        let currentGroup = Workspace.get(byName: "Current-browser-group")
        var tree = SurfaceTree(); tree.reconcile([old], in: oldGroup.name); tree.reconcile([current], in: currentGroup.name)
        local.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [oldGroup.name, currentGroup.name],
                                            selected: nil, closedBrowserTabs: []))
        local.connected(localConnection, processID: -1) { _, reply in reply(.issued) }
        defer { local.disconnected(localConnection) }
        local.received(.init(revision: 1, full: true, tabs: [record(old), record(current)]),
                       epoch: localEpoch, connection: localConnection, protocolVersion: 4)
        XCTAssertEqual(local.select(current), .issued)
        XCTAssertTrue(focus.workspace === currentGroup)
        XCTAssertFalse(oldGroup.isVisible)
        local.cancelPendingBrowserFocusHold()
        local.received(.init(revision: 2, full: true, tabs: [record(old, focused: true), record(current)]),
                       epoch: localEpoch, connection: localConnection, protocolVersion: 4)
        XCTAssertEqual(local.focusCoordinator.target, current)
        XCTAssertTrue(focus.workspace === currentGroup)
        XCTAssertTrue(local.plannedSurfaces(in: oldGroup).allSatisfy { !$0.visible })
    }
}
