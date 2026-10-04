@testable import AppBundle
import AppKit
import Common
import WorkspaceCore
import XCTest

@MainActor final class WorkspaceViewsTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.workspaceInteractionMode = .views
    }

    override func tearDown() async throws { config.workspaceInteractionMode = .tiling }

    func testModeIsOptInAndRejectsUnknownValues() {
        XCTAssertEqual(parseConfig("").0.workspaceInteractionMode, .tiling)
        let (parsed, errors) = parseConfig("workspace-interaction-mode = 'views'")
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(parsed.workspaceInteractionMode, .views)
        XCTAssertFalse(parseConfig("workspace-interaction-mode = 'invalid'").1.isEmpty)
    }

    func testSearchDoesNotPresentOneMatchingMemberAsAStandaloneView() throws {
        let workspace = WorkspaceSidebarWorkspaceViewModel(name: "group", projectId: workspaceProjectDefaultId,
            displayName: "Research", sidebarLabel: "", isGeneratedName: false, monitorScopeId: "test",
            monitorName: nil, isFocused: false, isVisible: true, items: ["Notes", "Reference"].map { title in
                .init(kind: .surface(.init(surfaceID: .nativeWindow(UUID()), title: title, appName: "App", isFocused: false)))
            }, isViewMode: true)
        let filtered = workspaceSidebarFilteredWorkspacesByProject([workspaceProjectDefaultId: [workspace]], projects: [], query: "Reference")
        let result = try XCTUnwrap(filtered[workspaceProjectDefaultId]?.first)
        XCTAssertEqual(result.viewSurfaces.count, 1)
        XCTAssertEqual(result.viewSurfaceCount, 2)
        XCTAssertFalse(result.isSingleWindowView, "The matching member must retain its own activation row")
    }

    func testBrowserCreationAllocatesExactlyOneViewInEitherArrivalOrder() throws {
        for inventoryFirst in [true, false] {
            setUpWorkspacesForTests(); config.workspaceInteractionMode = .views
            let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
            controller.usesSurfaceTree = true
            let original = focus.workspace
            let existing = TestWindow.new(id: 91, parent: original.rootTilingContainer)
            let id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
            var callback: (@MainActor (BrowserActionReply, SurfaceID?) -> Void)?
            controller.connected(connection, processID: -1, sendNewTab: { _, reply in callback = reply }, send: { _, reply in reply(.issued) })
            controller.received(.init(revision: 1, full: true, tabs: []), epoch: epoch, connection: connection, protocolVersion: 5)
            XCTAssertEqual(controller.openBrowserTab(), .issued)
            let message = BrowserInventoryMessage(revision: 2, full: true,
                tabs: [.init(surfaceID: id, hostID: "new", title: "New", selected: true)])
            if inventoryFirst { controller.received(message, epoch: epoch, connection: connection, protocolVersion: 5) }
            let provisional = controller.workspaceName(for: id)
            callback?(.issued, id)
            if !inventoryFirst { controller.received(message, epoch: epoch, connection: connection, protocolVersion: 5) }
            let destination = try XCTUnwrap(controller.workspaceName(for: id))
            XCTAssertNotEqual(destination, original.name)
            if inventoryFirst { XCTAssertEqual(destination, provisional) }
            XCTAssertTrue(existing.nodeWorkspace === original)
            XCTAssertEqual(Workspace.existing(byName: destination)?.projectId, original.projectId)
            XCTAssertEqual(controller.focusCoordinator.target, id)
            controller.disconnected(connection)
        }
    }

    func testMultipleBackgroundArrivalsHaveSeparateViewsWithoutSelection() throws {
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
        controller.usesSurfaceTree = true
        let original = focus.workspace
        let ids = (0..<3).map { _ in SurfaceID.browserTab(profile: UUID(), tab: UUID()) }
        controller.connected(connection, processID: -1, send: { _, reply in reply(.issued) })
        controller.received(.init(revision: 1, full: true, tabs: ids.map {
            .init(surfaceID: $0, hostID: $0.description, title: "Background", selected: false)
        }), epoch: epoch, connection: connection, protocolVersion: 5)
        XCTAssertEqual(Set(ids.compactMap { controller.workspaceName(for: $0) }).count, 3)
        XCTAssertNil(controller.focusCoordinator.target)
        XCTAssertTrue(focus.workspace === original)
        controller.disconnected(connection)
    }

    func testNativeArrivalDoesNotShrinkExistingViewOrUseNamedEmptyGroup() {
        let controller = BrowserWorkspaceController(), original = focus.workspace
        let first = TestWindow.new(id: 92, parent: original.rootTilingContainer)
        let second = TestWindow.new(id: 93, parent: original.rootTilingContainer)
        controller.placeOrdinaryNativeArrival(second, in: original)
        XCTAssertTrue(first.nodeWorkspace === original)
        XCTAssertFalse(second.nodeWorkspace === original)
        XCTAssertEqual(second.nodeWorkspace?.allLeafWindowsRecursive.count, 1)
        XCTAssertEqual(second.nodeWorkspace?.projectId, original.projectId)
        let floating = TestWindow.new(id: 94, parent: original)
        controller.placeOrdinaryNativeArrival(floating, in: original)
        XCTAssertTrue(floating.nodeWorkspace === original)
    }

    func testAllocatorRetainsMinimizedAndNamedEmptyViews() {
        let controller = BrowserWorkspaceController(), original = focus.workspace
        original.markAsAutomaticallyNamed()
        let minimized = TestWindow.new(id: 97, parent: original.rootTilingContainer)
        minimized.rememberMacOsLayoutOrigin()
        minimized.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        let named = Workspace.get(byName: "Keep this empty view")
        let destination = controller.newStandaloneWorkspace(in: original)
        XCTAssertFalse(destination === original)
        XCTAssertFalse(destination === named)
        XCTAssertEqual(workspaceOwnedMinimizedWindows(original).map(\.windowId), [97])
        XCTAssertTrue(isUserFacingWorkspace(named))
    }

    func testDelayedBrowserCreationKeepsCapturedSpaceAndDoesNotTakeBackFocus() throws {
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
        controller.usesSurfaceTree = true
        let original = focus.workspace
        _ = TestWindow.new(id: 98, parent: original.rootTilingContainer)
        var callback: (@MainActor (BrowserActionReply, SurfaceID?) -> Void)?
        controller.connected(connection, processID: -1, sendNewTab: { _, reply in callback = reply }, send: { _, reply in reply(.issued) })
        controller.received(.init(revision: 1, full: true, tabs: []), epoch: epoch, connection: connection, protocolVersion: 5)
        XCTAssertEqual(controller.openBrowserTab(), .issued)
        let otherSpace = createWorkspaceProject()
        let other = createBlankWorkspace(projectId: otherSpace.id, monitor: original.workspaceMonitor)
        let selected = TestWindow.new(id: 99, parent: other.rootTilingContainer)
        _ = controller.select(selected.surfaceID)
        let tab = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        controller.received(.init(revision: 2, full: true, tabs: [
            .init(surfaceID: tab, hostID: "delayed", title: "Delayed", selected: false),
        ]), epoch: epoch, connection: connection, protocolVersion: 5)
        callback?(.issued, tab)
        let destination = try XCTUnwrap(controller.workspaceName(for: tab).flatMap { Workspace.existing(byName: $0) })
        XCTAssertEqual(destination.projectId, original.projectId)
        XCTAssertNotEqual(destination.name, original.name)
        XCTAssertEqual(controller.focusCoordinator.target, selected.surfaceID)
        controller.disconnected(connection)
    }

    func testFailedBrowserCreationDoesNotAllocateAView() {
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
        controller.usesSurfaceTree = true
        controller.connected(connection, processID: -1, sendNewTab: { _, reply in reply(.unavailable, nil) }, send: { _, reply in reply(.issued) })
        controller.received(.init(revision: 1, full: true, tabs: []), epoch: epoch, connection: connection, protocolVersion: 5)
        let names = Set(Workspace.all.map(\.name))
        _ = controller.openBrowserTab()
        XCTAssertEqual(Set(Workspace.all.map(\.name)), names)
        XCTAssertNil(controller.focusCoordinator.target)
        controller.disconnected(connection)
    }

    func testSeparatingSingletonIsNoOpAndPreservesItsName() {
        let controller = BrowserWorkspaceController(), workspace = focus.workspace
        let window = TestWindow.new(id: 100, parent: workspace.rootTilingContainer)
        var tree = SurfaceTree(); tree.reconcile([window.surfaceID], in: workspace.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        let names = Set(Workspace.all.map(\.name))
        XCTAssertFalse(controller.canSeparateView(window.surfaceID))
        XCTAssertFalse(controller.separateView(window.surfaceID))
        XCTAssertTrue(window.nodeWorkspace === workspace)
        XCTAssertEqual(Set(Workspace.all.map(\.name)), names)
    }

    func testReplacingNativePinKeepsPreviousWindowStandalone() throws {
        let controller = BrowserWorkspaceController(), regular = focus.workspace
        let previousPath = TestApp.shared.bundlePath
        TestApp.shared.bundlePath = "/Missing/Test.app"
        defer { TestApp.shared.bundlePath = previousPath }
        let first = TestWindow.new(id: 104, parent: regular.rootTilingContainer)
        let second = TestWindow.new(id: 105, parent: regular.rootTilingContainer)
        let unrelated = TestWindow.new(id: 106, parent: regular.rootTilingContainer)
        var tree = SurfaceTree(); tree.reconcile([first.surfaceID, second.surfaceID, unrelated.surfaceID], in: regular.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        XCTAssertTrue(controller.pinSurface(first.surfaceID))
        XCTAssertTrue(controller.pinSurface(second.surfaceID))
        XCTAssertEqual(controller.nativeAppSidebarPins.count, 1)
        XCTAssertEqual(controller.nativeAppSidebarPins.first?.surfaceID, second.surfaceID)
        XCTAssertTrue(second.nodeWorkspace?.isPinnedGroup == true)
        XCTAssertFalse(first.nodeWorkspace === regular)
        XCTAssertEqual(first.nodeWorkspace?.allLeafWindowsRecursive.count, 1)
        XCTAssertTrue(unrelated.nodeWorkspace === regular)
        XCTAssertNoThrow(try controller.capturePlacementSnapshot()?.validated())
    }

    func testUnpinDuringBrowserReopenPlacesCreatedPageInItsOwnView() throws {
        let controller = BrowserWorkspaceController(), regular = focus.workspace
        controller.usesSurfaceTree = true
        _ = TestWindow.new(id: 107, parent: regular.rootTilingContainer)
        let pinned = controller.pinnedGroup(for: regular.projectId, source: regular)
        let profile = UUID(), tab = SurfaceID.browserTab(profile: profile, tab: UUID())
        let pin = BrowserSidebarPin(profileID: profile, workspaceName: pinned.name, title: "Docs", url: "https://example.com")
        controller.browserSidebarPins = [pin]
        let connection = UUID(), epoch = UUID()
        var callback: (@MainActor (BrowserActionReply, SurfaceID?) -> Void)?
        controller.connected(connection, processID: -1, sendNewTab: { _, reply in callback = reply }, send: { _, reply in reply(.issued) })
        controller.received(.init(revision: 1, full: true, tabs: []), epoch: epoch, connection: connection, protocolVersion: 5)
        XCTAssertEqual(controller.selectPinnedBrowserTab(pin.id), .issued)
        XCTAssertTrue(controller.unpin(pin.id))
        callback?(.issued, tab)
        controller.received(.init(revision: 2, full: true, tabs: [
            .init(surfaceID: tab, hostID: "reopened", title: "Docs", selected: false),
        ]), epoch: epoch, connection: connection, protocolVersion: 5)
        let destination = try XCTUnwrap(controller.workspaceName(for: tab))
        XCTAssertNotEqual(destination, pinned.name)
        XCTAssertNotEqual(destination, regular.name)
        XCTAssertEqual(controller.surfaceTree.roots[destination]?.flatMap(\.surfaces), [tab])
        XCTAssertTrue(controller.browserSidebarPins.isEmpty)
        controller.disconnected(connection)
    }

    func testPinnedViewsSelectIndependentlyAndUnpinIntoStandaloneView() throws {
        let controller = BrowserWorkspaceController(), regular = focus.workspace
        controller.usesSurfaceTree = true
        _ = TestWindow.new(id: 101, parent: regular.rootTilingContainer)
        let pinned = controller.pinnedGroup(for: regular.projectId, source: regular)
        let first = TestWindow.new(id: 102, parent: pinned.rootTilingContainer)
        let second = TestWindow.new(id: 103, parent: pinned.rootTilingContainer)
        var tree = SurfaceTree(); tree.reconcile([first.surfaceID, second.surfaceID], in: pinned.name)
        let pin = NativeAppSidebarPin(workspaceName: pinned.name, bundleIdentifier: "test.app", bundlePath: "/Missing/Test.app", title: "First", surfaceID: first.surfaceID)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [pinned.name], selected: nil, closedBrowserTabs: [],
            appPins: [pin], pinnedGroups: controller.spacePinnedGroups, selectedByWorkspace: [pinned.name: second.surfaceID]))
        XCTAssertTrue(pinned.focusWorkspace(restoringSurfaceSelection: false))
        XCTAssertEqual(controller.preferredSurface(in: pinned), second.surfaceID)
        XCTAssertEqual(controller.plannedSurfaces(in: pinned).filter(\.visible).map(\.surfaceID), [second.surfaceID])
        XCTAssertEqual(controller.select(first.surfaceID), .issued)
        XCTAssertEqual(controller.plannedSurfaces(in: pinned).filter(\.visible).map(\.surfaceID), [first.surfaceID])
        XCTAssertTrue(controller.combineViews(second.surfaceID, with: first.surfaceID, layout: .horizontal))
        XCTAssertEqual(controller.plannedSurfaces(in: pinned).filter(\.visible).count, 2)
        XCTAssertTrue(controller.separateView(second.surfaceID))
        XCTAssertTrue(second.nodeWorkspace === pinned)
        XCTAssertEqual(controller.plannedSurfaces(in: pinned).filter(\.visible).map(\.surfaceID), [second.surfaceID])
        XCTAssertTrue(controller.unpin(pin.id))
        XCTAssertFalse(first.nodeWorkspace === regular)
        XCTAssertFalse(first.nodeWorkspace === pinned)
        XCTAssertEqual(first.nodeWorkspace?.allLeafWindowsRecursive.count, 1)
        XCTAssertNoThrow(try controller.capturePlacementSnapshot()?.validated())
    }

    func testCombineSeparateAndPinnedBoundaryAreTransactional() throws {
        let controller = BrowserWorkspaceController(), firstWorkspace = focus.workspace
        let secondWorkspace = createBlankWorkspace(projectId: firstWorkspace.projectId, monitor: firstWorkspace.workspaceMonitor)
        let first = TestWindow.new(id: 95, parent: firstWorkspace.rootTilingContainer)
        let second = TestWindow.new(id: 96, parent: secondWorkspace.rootTilingContainer)
        var tree = SurfaceTree()
        tree.reconcile([first.surfaceID], in: firstWorkspace.name)
        tree.reconcile([second.surfaceID], in: secondWorkspace.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        XCTAssertTrue(controller.combineViews(second.surfaceID, with: first.surfaceID, layout: .horizontal))
        XCTAssertTrue(second.nodeWorkspace === firstWorkspace)
        XCTAssertEqual(controller.surfaceTree.roots[firstWorkspace.name]?.count, 1)
        XCTAssertTrue(controller.separateView(second.surfaceID))
        XCTAssertFalse(second.nodeWorkspace === firstWorkspace)
        let snapshot = controller.surfaceTree
        second.nodeWorkspace?.isPinnedGroup = true
        XCTAssertFalse(controller.combineViews(second.surfaceID, with: first.surfaceID, layout: .stack))
        XCTAssertEqual(controller.surfaceTree, snapshot)
    }
}
