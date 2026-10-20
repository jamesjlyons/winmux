@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor
final class DwindleArrivalTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.newItemPlacement = .tile
        config.tilingAlgorithm = .dwindle
    }

    func testNativeArrivalSplitsFocusedPortraitPaneAndKeepsItsOuterWeight() throws {
        let root = focus.workspace.rootTilingContainer
        let source = TestWindow.new(id: 401, parent: root, adaptiveWeight: 300)
        let other = TestWindow.new(id: 402, parent: root, adaptiveWeight: 700)
        source.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 800)
        XCTAssertTrue(source.focusWindow())
        let binding = bindingDataForNewTilingWindow(focus.workspace, window: nil)
        let parent = try XCTUnwrap(binding.parent as? TilingContainer)
        let arrival = TestWindow.new(id: 403, parent: focus.workspace)
        arrival.bind(to: parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
        XCTAssertEqual(parent.orientation, .v)
        XCTAssertEqual(parent.children, [source, arrival])
        XCTAssertEqual(root.children, [parent, other])
        XCTAssertEqual(parent.hWeight, 300)
        XCTAssertEqual(other.hWeight, 700)
        XCTAssertEqual(source.vWeight, arrival.vWeight)
    }

    func testNativeLandscapeArrivalReusesParentAndNewViewBypassesDwindle() throws {
        let root = focus.workspace.rootTilingContainer
        let source = TestWindow.new(id: 401, parent: root)
        _ = TestWindow.new(id: 402, parent: root)
        source.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 600)
        XCTAssertTrue(source.focusWindow())
        let binding = bindingDataForNewTilingWindow(focus.workspace, window: nil)
        XCTAssertTrue(binding.parent === root)
        XCTAssertEqual(binding.index, 1)
        config.newItemPlacement = .newView
        source.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 800)
        XCTAssertTrue(bindingDataForNewTilingWindow(focus.workspace, window: nil).parent === root)
    }

    func testNativeStackPolicyStillAddsToFocusedStack() {
        config.newItemPlacement = .stackNative
        let stack = TilingContainer(parent: focus.workspace.rootTilingContainer, adaptiveWeight: 1, .v, .tabGroup, index: INDEX_BIND_LAST)
        let source = TestWindow.new(id: 401, parent: stack)
        _ = TestWindow.new(id: 402, parent: stack)
        XCTAssertTrue(source.focusWindow())
        let binding = bindingDataForNewTilingWindow(focus.workspace, window: nil)
        XCTAssertTrue(binding.parent === stack)
        XCTAssertEqual(binding.index, 1)
    }

    func testSharedNativeArrivalCanSplitBesideBrowserPage() throws {
        let controller = BrowserWorkspaceController(), workspace = focus.workspace
        controller.usesSurfaceTree = true
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let connection = UUID()
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [
            .init(surfaceID: page, hostID: page.description, title: "Page", selected: true)
        ]), epoch: UUID(), connection: connection, protocolVersion: 11)
        let other = TestWindow.new(id: 401, parent: workspace.rootTilingContainer)
        controller.surfaceTree.reconcile([page, other.surfaceID], in: workspace.name)
        // Give the page a narrow column regardless of the test display size.
        controller.surfaceTree.setWeights([page.description: 100, other.surfaceID.description: 1000])
        _ = controller.focusCoordinator.select(page)
        let arrival = TestWindow.new(id: 402, parent: workspace.rootTilingContainer)
        controller.placeOrdinaryNativeArrival(arrival, in: workspace)
        let group = try XCTUnwrap(controller.surfaceTree.containingGroup(of: page))
        XCTAssertEqual(controller.surfaceTree.layouts[group], .vertical)
        XCTAssertEqual(controller.surfaceTree.group(group)?.surfaces, [page, arrival.surfaceID])
        XCTAssertEqual(controller.surfaceTree.roots[workspace.name]?.last, .surface(other.surfaceID))
    }

    func testBrowserCreationKeepsCapturedSourceInEitherReplyOrder() throws {
        for inventoryFirst in [false, true] {
            setUpWorkspacesForTests()
            config.newItemPlacement = .tile
            config.tilingAlgorithm = .dwindle
            let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID(), profile = UUID()
            controller.usesSurfaceTree = true
            let workspace = focus.workspace
            let source = SurfaceID.browserTab(profile: profile, tab: UUID())
            let other = SurfaceID.browserTab(profile: profile, tab: UUID())
            let created = SurfaceID.browserTab(profile: profile, tab: UUID())
            var reply: (@MainActor (BrowserActionReply, SurfaceID?) -> Void)?
            controller.connected(connection, processID: -1, sendNewTab: { _, callback in reply = callback }, send: { _, callback in callback(.issued) })
            controller.surfaceTree.reconcile([source, other], in: workspace.name)
            controller.received(.init(revision: 1, full: true, tabs: [source, other].map {
                .init(surfaceID: $0, hostID: $0.description, title: "Page", selected: false)
            }), epoch: epoch, connection: connection, protocolVersion: 5)
            controller.surfaceTree.setWeights([source.description: 100, other.description: 1000])
            _ = controller.select(source)
            XCTAssertEqual(controller.openBrowserTab(), .issued)
            _ = controller.select(other)
            let inventory = BrowserInventoryMessage(revision: 2, full: true, tabs: [source, other, created].map {
                .init(surfaceID: $0, hostID: $0.description, title: "Page", selected: false)
            })
            if inventoryFirst { controller.received(inventory, epoch: epoch, connection: connection, protocolVersion: 5) }
            reply?(.issued, created)
            if !inventoryFirst { controller.received(inventory, epoch: epoch, connection: connection, protocolVersion: 5) }
            let group = try XCTUnwrap(controller.surfaceTree.containingGroup(of: source))
            XCTAssertEqual(controller.surfaceTree.layouts[group], .vertical)
            XCTAssertEqual(controller.surfaceTree.group(group)?.surfaces, [source, created])
            XCTAssertEqual(controller.surfaceTree.weights[SurfacePane.group(group).weightKey], 100)
            XCTAssertEqual(controller.surfaceTree.weights[other.description], 1000)
            XCTAssertEqual(controller.focusCoordinator.target, other)
            XCTAssertEqual(controller.surfaceTree.roots[workspace.name]?.flatMap(\.surfaces), [source, created, other])
            controller.disconnected(connection)
        }
    }

    func testExplicitPlacementAndAdaptiveKeepRootArrivalBehavior() {
        let controller = BrowserWorkspaceController(), workspace = focus.workspace
        controller.usesSurfaceTree = true
        let source = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let other = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let created = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        for algorithm in TilingAlgorithm.allCases {
            config.tilingAlgorithm = algorithm
            controller.surfaceTree = SurfaceTree()
            controller.surfaceTree.reconcile([source, other], in: workspace.name)
            controller.placeCreatedBrowserTab(created, in: workspace.name, focusAddress: false, selectCreated: false,
                focusGeneration: 0, after: source, tileArrival: algorithm == .adaptive)
            XCTAssertEqual(controller.surfaceTree.roots[workspace.name], [.surface(source), .surface(created), .surface(other)])
        }
    }

    func testInventoryOnlyArrivalTilesButInitialInventoryKeepsExistingArrangement() throws {
        let controller = BrowserWorkspaceController(), workspace = focus.workspace
        let connection = UUID(), epoch = UUID(), profile = UUID()
        controller.usesSurfaceTree = true
        let source = SurfaceID.browserTab(profile: profile, tab: UUID())
        let other = SurfaceID.browserTab(profile: profile, tab: UUID())
        let created = SurfaceID.browserTab(profile: profile, tab: UUID())
        controller.surfaceTree.reconcile([source, other], in: workspace.name)
        let original = controller.surfaceTree
        controller.connected(connection, processID: -1, send: { _, reply in reply(.issued) })
        controller.received(.init(revision: 1, full: true, tabs: [source, other].map {
            .init(surfaceID: $0, hostID: $0.description, title: "Restored", selected: false)
        }), epoch: epoch, connection: connection, protocolVersion: 5)
        XCTAssertEqual(controller.surfaceTree.roots[workspace.name], original.roots[workspace.name])
        controller.surfaceTree.setWeights([source.description: 100, other.description: 1000])
        _ = controller.select(source)
        controller.received(.init(revision: 2, full: false, tabs: [
            .init(surfaceID: created, hostID: "created", title: "New", selected: false),
        ]), epoch: epoch, connection: connection, protocolVersion: 5)
        let group = try XCTUnwrap(controller.surfaceTree.containingGroup(of: source))
        XCTAssertEqual(controller.surfaceTree.layouts[group], .vertical)
        XCTAssertEqual(controller.surfaceTree.group(group)?.surfaces, [source, created])
        // A later snapshot is a membership update, not another arrival.
        let placed = controller.surfaceTree
        controller.received(.init(revision: 3, full: false, tabs: [
            .init(surfaceID: created, hostID: "created", title: "Updated title", selected: false),
        ]), epoch: epoch, connection: connection, protocolVersion: 5)
        XCTAssertEqual(controller.surfaceTree, placed)
        controller.disconnected(connection)
    }
}
