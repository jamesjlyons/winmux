@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor final class NewItemOrderingTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.newItemPlacement = .newView
    }

    override func tearDown() async throws { config.newItemPlacement = .tile }

    private func assertImmediatelyAfter(_ destination: Workspace, _ source: Workspace,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let order = projectWorkspaces(projectId: source.projectId)
        let index = order.firstIndex(of: source)
        XCTAssertNotNil(index, file: file, line: line)
        XCTAssertEqual(order.firstIndex(of: destination), index.map { $0 + 1 }, file: file, line: line)
    }

    func testNativeArrivalInsertsAfterSourceWithLaterViews() throws {
        let controller = BrowserWorkspaceController(), source = focus.workspace
        _ = TestWindow.new(id: 301, parent: source.rootTilingContainer)
        let later = createBlankWorkspace(projectId: source.projectId, monitor: source.workspaceMonitor)
        _ = TestWindow.new(id: 302, parent: later.rootTilingContainer)
        let arrival = TestWindow.new(id: 303, parent: source.rootTilingContainer)

        controller.placeOrdinaryNativeArrival(arrival, in: source)

        assertImmediatelyAfter(try XCTUnwrap(arrival.nodeWorkspace), source)
        assertImmediatelyAfter(later, try XCTUnwrap(arrival.nodeWorkspace))
    }

    func testReusedEmptyViewMovesFromBeforeSourceToImmediatelyAfterIt() {
        let controller = BrowserWorkspaceController(), blank = focus.workspace
        blank.markAsAutomaticallyNamed()
        let source = createBlankWorkspace(projectId: blank.projectId, monitor: blank.workspaceMonitor)
        _ = TestWindow.new(id: 304, parent: source.rootTilingContainer)
        let later = createBlankWorkspace(projectId: source.projectId, monitor: source.workspaceMonitor)
        _ = TestWindow.new(id: 305, parent: later.rootTilingContainer)

        let destination = controller.newStandaloneWorkspace(in: source)

        XCTAssertTrue(destination === blank)
        assertImmediatelyAfter(destination, source)
        assertImmediatelyAfter(later, destination)
    }

    func testArrivalFromPinInsertsBeforeExistingRegularViews() {
        let controller = BrowserWorkspaceController(), first = focus.workspace
        _ = TestWindow.new(id: 311, parent: first.rootTilingContainer)
        let later = createBlankWorkspace(projectId: first.projectId, monitor: first.workspaceMonitor)
        _ = TestWindow.new(id: 312, parent: later.rootTilingContainer)
        let pinned = controller.pinnedGroup(for: first.projectId, source: first)

        let destination = controller.newStandaloneWorkspace(in: pinned)

        XCTAssertFalse(destination.isPinnedGroup)
        assertImmediatelyAfter(destination, pinned)
        assertImmediatelyAfter(first, destination)
    }

    func testPrivateBrowserArrivalInsertsAfterItsSourceView() throws {
        let controller = BrowserWorkspaceController(), profile = UUID()
        let first = controller.incognitoDestination(.browserTab(profile: profile, tab: UUID()), from: focus.workspace)
        let source = try XCTUnwrap(Workspace.existing(byName: first))
        let later = controller.incognitoDestination(.browserTab(profile: profile, tab: UUID()), from: source)
        let laterWorkspace = try XCTUnwrap(Workspace.existing(byName: later))
        let last = controller.incognitoDestination(.browserTab(profile: profile, tab: UUID()), from: laterWorkspace)
        let created = controller.incognitoDestination(.browserTab(profile: profile, tab: UUID()), from: laterWorkspace)

        let destination = try XCTUnwrap(Workspace.existing(byName: created))
        assertImmediatelyAfter(destination, laterWorkspace)
        assertImmediatelyAfter(try XCTUnwrap(Workspace.existing(byName: last)), destination)
    }

    func testBrowserReplyKeepsOriginalSourceAfterFocusChangesInEitherArrivalOrder() throws {
        for inventoryFirst in [false, true] {
            setUpWorkspacesForTests()
            config.newItemPlacement = .newView
            let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
            controller.usesSurfaceTree = true
            let source = focus.workspace
            let original = TestWindow.new(id: 306, parent: source.rootTilingContainer)
            let later = createBlankWorkspace(projectId: source.projectId, monitor: source.workspaceMonitor)
            let other = TestWindow.new(id: 307, parent: later.rootTilingContainer)
            var callback: (@MainActor (BrowserActionReply, SurfaceID?) -> Void)?
            controller.connected(connection, processID: -1, sendNewTab: { _, reply in callback = reply }, send: { _, reply in reply(.issued) })
            controller.received(.init(revision: 1, full: true, tabs: []), epoch: epoch, connection: connection, protocolVersion: 5)
            _ = controller.select(original.surfaceID)
            XCTAssertEqual(controller.openBrowserTab(), .issued)
            _ = controller.select(other.surfaceID)
            let tab = SurfaceID.browserTab(profile: UUID(), tab: UUID())
            let inventory = BrowserInventoryMessage(revision: 2, full: true, tabs: [
                .init(surfaceID: tab, hostID: "new", title: "New", selected: false),
            ])
            if inventoryFirst { controller.received(inventory, epoch: epoch, connection: connection, protocolVersion: 5) }
            let provisional = controller.workspaceName(for: tab)
            callback?(.issued, tab)
            if !inventoryFirst { controller.received(inventory, epoch: epoch, connection: connection, protocolVersion: 5) }

            let destination = try XCTUnwrap(controller.workspaceName(for: tab).flatMap { Workspace.existing(byName: $0) })
            if inventoryFirst { XCTAssertEqual(destination.name, provisional) }
            assertImmediatelyAfter(destination, source)
            assertImmediatelyAfter(later, destination)
            XCTAssertEqual(controller.focusCoordinator.target, other.surfaceID)
            controller.disconnected(connection)
        }
    }

    func testToolbarUsesItsOwnPageAndOwnerWhenAnotherPageIsFocused() throws {
        let controller = BrowserWorkspaceController(), connection = UUID(), otherConnection = UUID(), epoch = UUID(), profile = UUID()
        controller.usesSurfaceTree = true
        let source = SurfaceID.browserTab(profile: profile, tab: UUID())
        let focused = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let created = SurfaceID.browserTab(profile: profile, tab: UUID())
        var request: BrowserNewTabRequest?
        controller.connected(connection, processID: -1, sendNewTab: { value, reply in
            request = value
            reply(.issued, created)
        }, send: { _, reply in reply(.issued) })
        controller.received(.init(revision: 1, full: true, tabs: [
            .init(surfaceID: source, hostID: "source", title: "Source", selected: false),
        ]), epoch: epoch, connection: connection, protocolVersion: 5)
        controller.connected(otherConnection, processID: -2, sendNewTab: { _, _ in
            XCTFail("Creation must go to the toolbar page's owner")
        }, send: { _, reply in reply(.issued) })
        controller.received(.init(revision: 1, full: true, tabs: [
            .init(surfaceID: focused, hostID: "focused", title: "Focused", selected: false),
        ]), epoch: UUID(), connection: otherConnection, protocolVersion: 5)
        _ = controller.select(focused)

        controller.performToolbarAction(.newTab, for: source)

        XCTAssertEqual(request?.sourceSurfaceID, source)
        let sourceWorkspace = try XCTUnwrap(controller.workspaceName(for: source).flatMap { Workspace.existing(byName: $0) })
        let destination = try XCTUnwrap(controller.workspaceName(for: created).flatMap { Workspace.existing(byName: $0) })
        assertImmediatelyAfter(destination, sourceWorkspace)
        controller.disconnected(connection)
        controller.disconnected(otherConnection)
    }

    func testNativeTabGroupArrivalInsertsAfterFocusedTab() {
        config.newItemPlacement = .tile
        config.newItemPlacement = .stackNative
        let workspace = focus.workspace
        let group = TilingContainer(parent: workspace.rootTilingContainer, adaptiveWeight: 1, .v, .tabGroup, index: INDEX_BIND_LAST)
        let source = TestWindow.new(id: 308, parent: group)
        _ = TestWindow.new(id: 309, parent: group)
        XCTAssertTrue(source.focusWindow())

        let binding = bindingDataForNewTilingWindow(workspace, window: nil)
        let arrival = TestWindow.new(id: 310, parent: workspace)
        arrival.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)

        XCTAssertEqual(group.children.compactMap { ($0 as? Window)?.windowId }, [308, 310, 309])
    }

    func testBrowserCreationInTilingModeInsertsAfterSourceBeforeLaterItems() throws {
        config.newItemPlacement = .tile
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID(), profile = UUID()
        controller.usesSurfaceTree = true
        let workspace = focus.workspace
        let source = SurfaceID.browserTab(profile: profile, tab: UUID())
        let later = SurfaceID.browserTab(profile: profile, tab: UUID())
        let created = SurfaceID.browserTab(profile: profile, tab: UUID())
        controller.connected(connection, processID: -1, sendNewTab: { _, reply in reply(.issued, created) }, send: { _, reply in reply(.issued) })
        controller.surfaceTree.reconcile([source, later], in: workspace.name)
        controller.received(.init(revision: 1, full: true, tabs: [source, later].map {
            .init(surfaceID: $0, hostID: $0.description, title: "Page", selected: false)
        }), epoch: epoch, connection: connection, protocolVersion: 5)
        _ = controller.select(source)

        XCTAssertEqual(controller.openBrowserTab(), .issued)

        XCTAssertEqual(controller.surfaceTree.roots[workspace.name]?.flatMap(\.surfaces), [source, created, later])
        controller.disconnected(connection)
    }
}
