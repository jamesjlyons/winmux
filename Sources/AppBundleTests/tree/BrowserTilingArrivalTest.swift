@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor
final class BrowserTilingArrivalTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.newItemPlacement = .tile
    }

    func testAdaptiveCreationJoinsFocusedSplitInEitherReplyOrder() throws {
        for inventoryFirst in [false, true] {
            setUpWorkspacesForTests()
            config.newItemPlacement = .tile
            config.tilingAlgorithm = .adaptive
            let controller = BrowserWorkspaceController(), workspace = focus.workspace
            let connection = UUID(), epoch = UUID(), profile = UUID()
            let pages = (0..<4).map { _ in SurfaceID.browserTab(profile: profile, tab: UUID()) }
            let (source, sibling, other, arrival) = (pages[0], pages[1], pages[2], pages[3])
            controller.usesSurfaceTree = true
            controller.surfaceTree.reconcile([source, sibling, other], in: workspace.name)
            XCTAssertTrue(controller.surfaceTree.group(sibling, with: source, layout: .vertical))
            let split = try XCTUnwrap(controller.surfaceTree.containingGroup(of: source))
            controller.surfaceTree.setWeights([source.description: 200, sibling.description: 400,
                SurfacePane.group(split).weightKey: 600, other.description: 900])
            var reply: (@MainActor (BrowserActionReply, SurfaceID?) -> Void)?
            controller.connected(connection, processID: -1, sendNewTab: { _, callback in reply = callback },
                send: { _, callback in callback(.issued) })
            controller.received(.init(revision: 1, full: true, tabs: pages.prefix(3).map {
                .init(surfaceID: $0, hostID: $0.description, title: "Page", selected: false)
            }), epoch: epoch, connection: connection, protocolVersion: 11)
            XCTAssertEqual(controller.select(source), .issued)
            XCTAssertEqual(controller.openBrowserTab(), .issued)
            XCTAssertEqual(controller.select(other), .issued)
            let inventory = BrowserInventoryMessage(revision: 2, full: true, tabs: pages.map {
                .init(surfaceID: $0, hostID: $0.description, title: "Page", selected: false)
            })
            if inventoryFirst { controller.received(inventory, epoch: epoch, connection: connection, protocolVersion: 11) }
            reply?(.issued, arrival)
            if !inventoryFirst { controller.received(inventory, epoch: epoch, connection: connection, protocolVersion: 11) }
            XCTAssertEqual(controller.surfaceTree.group(split)?.surfaces, [source, arrival, sibling])
            XCTAssertEqual(controller.surfaceTree.roots[workspace.name]?.last, .surface(other))
            XCTAssertEqual(controller.surfaceTree.weights[source.description], 200)
            XCTAssertEqual(controller.surfaceTree.weights[sibling.description], 400)
            XCTAssertEqual(controller.surfaceTree.weights[SurfacePane.group(split).weightKey], 600)
            XCTAssertEqual(controller.focusCoordinator.target, other)
            controller.disconnected(connection)
        }
    }

    func testFirstBrowserCreationImportsNativeLayoutBeforeChoosingSplit() throws {
        for algorithm in TilingAlgorithm.allCases {
            setUpWorkspacesForTests()
            config.newItemPlacement = .tile
            config.tilingAlgorithm = algorithm
            let workspace = focus.workspace, controller = BrowserWorkspaceController()
            controller.usesSurfaceTree = true
            let root = workspace.rootTilingContainer
            let source = TestWindow.new(id: 501, parent: root, adaptiveWeight: 100)
            let other = TestWindow.new(id: 502, parent: root, adaptiveWeight: 1000)
            let arrival = SurfaceID.browserTab(profile: UUID(), tab: UUID())
            XCTAssertTrue(source.focusWindow())
            XCTAssertNil(controller.surfaceTree.roots[workspace.name])
            controller.placeCreatedBrowserTab(arrival, in: workspace.name, focusAddress: false,
                selectCreated: false, focusGeneration: 0, after: source.surfaceID, tileArrival: true)
            controller.reconcileSharedOrganization()
            XCTAssertEqual(controller.surfaceTree.roots[workspace.name]?.flatMap(\.surfaces),
                [source.surfaceID, arrival, other.surfaceID])
            XCTAssertEqual(controller.surfaceTree.weights[other.surfaceID.description], 1000)
            if algorithm == .dwindle {
                let split = try XCTUnwrap(controller.surfaceTree.containingGroup(of: source.surfaceID))
                XCTAssertEqual(controller.surfaceTree.layouts[split], .vertical)
                XCTAssertEqual(controller.surfaceTree.group(split)?.surfaces, [source.surfaceID, arrival])
                XCTAssertEqual(controller.surfaceTree.weights[SurfacePane.group(split).weightKey], 100)
            }
        }
    }

    func testAdaptiveInventoryAndNativeArrivalsJoinSplitBesideWholeStack() throws {
        config.tilingAlgorithm = .adaptive
        let controller = BrowserWorkspaceController(), workspace = focus.workspace
        let connection = UUID(), epoch = UUID(), profile = UUID()
        let pages = (0..<4).map { _ in SurfaceID.browserTab(profile: profile, tab: UUID()) }
        let (source, stacked, sibling, arrival) = (pages[0], pages[1], pages[2], pages[3])
        controller.usesSurfaceTree = true
        controller.surfaceTree.reconcile([source, sibling, stacked], in: workspace.name)
        XCTAssertTrue(controller.surfaceTree.group(sibling, with: source, layout: .vertical))
        let split = try XCTUnwrap(controller.surfaceTree.containingGroup(of: source))
        XCTAssertTrue(controller.surfaceTree.group(stacked, with: source, layout: .stack))
        let stack = try XCTUnwrap(controller.surfaceTree.stack(containing: source))
        controller.connected(connection, processID: -1, send: { _, callback in callback(.issued) })
        controller.received(.init(revision: 1, full: true, tabs: pages.prefix(3).map {
            .init(surfaceID: $0, hostID: $0.description, title: "Page", selected: false)
        }), epoch: epoch, connection: connection, protocolVersion: 11)
        XCTAssertEqual(controller.select(source), .issued)
        controller.received(.init(revision: 2, full: false, tabs: [
            .init(surfaceID: arrival, hostID: "new", title: "New page", selected: false),
        ]), epoch: epoch, connection: connection, protocolVersion: 11)
        XCTAssertEqual(controller.surfaceTree.group(split)?.surfaces, [source, stacked, arrival, sibling])
        let native = TestWindow.new(id: 503, parent: workspace.rootTilingContainer)
        controller.placeOrdinaryNativeArrival(native, in: workspace)
        XCTAssertEqual(controller.surfaceTree.group(split)?.surfaces, [source, stacked, native.surfaceID, arrival, sibling])
        XCTAssertEqual(controller.surfaceTree.group(stack)?.surfaces, [source, stacked])
        XCTAssertEqual(controller.surfaceTree.activeSurfaces[stack], source)
        controller.disconnected(connection)
    }
}
