@testable import AppBundle
import AppKit
import WorkspaceCore
import XCTest

@MainActor final class BrowserSurfaceDropTest: XCTestCase {
    private var nextWindowID: UInt32 = 1000

    override func setUp() async throws {
        setUpWorkspacesForTests()
        nextWindowID = 1000
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 1600, height: 1000)
        let monitor = TestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Main", rect: rect, visibleRect: rect, isMain: true)
        setMonitorsForTests([monitor])
        XCTAssertTrue(monitor.setActiveWorkspace(focus.workspace))
        config.windowTabs.enabled = true
    }

    func testBrowserAndNativeSourcesResolveAndSplitEachOther() throws {
        for browserSource in [true, false] {
            let fixture = fixture()
            let source = browserSource ? fixture.page : fixture.native.surfaceID
            let target = browserSource ? fixture.native.surfaceID : fixture.page
            let destination = try resolve(source: source, target: target, zone: .left, controller: fixture.controller)
            XCTAssertEqual(destination.source, source)
            XCTAssertEqual(destination.target, target)
            XCTAssertEqual(destination.overlay.activeZone, .left)
            XCTAssertTrue(commitBrowserSurfaceDrop(destination, controller: fixture.controller))
            let placements = fixture.controller.plannedSurfaces(in: focus.workspace)
            let moved = try XCTUnwrap(placements.first { $0.surfaceID == source })
            let anchor = try XCTUnwrap(placements.first { $0.surfaceID == target })
            XCTAssertLessThan(moved.frame.x, anchor.frame.x)
            XCTAssertTrue(moved.visible && anchor.visible)
            XCTAssertEqual(fixture.controller.focusCoordinator.target, source)
            fixture.native.unbindFromParent()
        }
    }

    func testNativeOnlyViewUsesSharedLayoutBeforeDropAndRetainsNativeOwnerBindings() throws {
        let controller = BrowserWorkspaceController(), workspace = focus.workspace
        let first = TestWindow.new(id: 4001, parent: workspace.rootTilingContainer)
        let second = TestWindow.new(id: 4002, parent: workspace.rootTilingContainer)
        let parent = first.parent
        var tree = SurfaceTree(); tree.reconcile([first.surfaceID, second.surfaceID], in: workspace.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        for window in [first, second] {
            window.lastAppliedLayoutPhysicalRect = try frame(for: window.surfaceID, controller: controller)
        }
        XCTAssertTrue(controller.hasSharedLayout(in: workspace), "Legacy adoption flags no longer defer native layout authority")
        let drop = try resolve(source: first.surfaceID, target: second.surfaceID, zone: .bottom, controller: controller)
        XCTAssertTrue(commitBrowserSurfaceDrop(drop, controller: controller))
        XCTAssertTrue(controller.hasSharedLayout(in: workspace))
        XCTAssertTrue(first.parent === parent && second.parent === parent)
        let firstFrame = try frame(for: first.surfaceID, controller: controller)
        let secondFrame = try frame(for: second.surfaceID, controller: controller)
        XCTAssertEqual(firstFrame.width, secondFrame.width)
        XCTAssertGreaterThan(firstFrame.topLeftY, secondFrame.topLeftY)
    }

    func testObservedLeftEdgeResizePreservesRightNeighborAndNativeWeights() throws {
        let fixture = fixture(secondPage: true), workspace = focus.workspace
        let right = try XCTUnwrap(fixture.other)
        let original = try frame(for: fixture.page, controller: fixture.controller)
        let rightBefore = try frame(for: right, controller: fixture.controller)
        let nativeBefore = try frame(for: fixture.native.surfaceID, controller: fixture.controller)
        let nativeWeight = fixture.native.getWeight(.h)
        let rect = CGRect(x: original.topLeftX, y: original.topLeftY, width: original.width, height: original.height)
        XCTAssertTrue(fixture.controller.resizeObservedSurface(fixture.page, from: rect,
            to: CGRect(x: rect.minX - 90, y: rect.minY, width: rect.width + 90, height: rect.height)))
        let result = try frame(for: fixture.page, controller: fixture.controller)
        XCTAssertEqual(result.width, original.width + 90)
        XCTAssertEqual(result.topLeftX, original.topLeftX - 90)
        XCTAssertTrue(try frame(for: right, controller: fixture.controller).isEqual(to: rightBefore))
        XCTAssertEqual(try frame(for: fixture.native.surfaceID, controller: fixture.controller).width, nativeBefore.width - 90)
        XCTAssertEqual(fixture.native.getWeight(.h), nativeWeight)
        XCTAssertEqual(fixture.native.nodeWorkspace, workspace)
    }

    func testObservedResizeRejectsDisconnectedOwnerWithoutPartialWeightChanges() throws {
        let fixture = fixture()
        let rect = try frame(for: fixture.native.surfaceID, controller: fixture.controller)
        let original = CGRect(x: rect.topLeftX, y: rect.topLeftY, width: rect.width, height: rect.height)
        fixture.controller.disconnected(fixture.connection)
        let before = fixture.controller.surfaceTree
        XCTAssertFalse(fixture.controller.resizeObservedSurface(fixture.native.surfaceID, from: original,
            to: CGRect(x: original.minX, y: original.minY, width: original.width + 90, height: original.height)))
        XCTAssertEqual(fixture.controller.surfaceTree, before)
        XCTAssertFalse(fixture.controller.resizeObservedSurface(fixture.native.surfaceID, from: original,
            to: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 400)))
        XCTAssertEqual(fixture.controller.surfaceTree, before)
    }

    func testBrowserToBrowserTabThenSplitUsesOnlyVisibleTarget() throws {
        let fixture = fixture(secondPage: true)
        let other = try XCTUnwrap(fixture.other)
        let destination = try resolve(source: other, target: fixture.page, zone: .tab, controller: fixture.controller)
        XCTAssertTrue(commitBrowserSurfaceDrop(destination, controller: fixture.controller))
        let visible = fixture.controller.plannedSurfaces(in: focus.workspace).filter(\.visible)
        XCTAssertFalse(visible.contains { $0.surfaceID == fixture.page })
        let split = try resolve(source: fixture.native.surfaceID, target: other, zone: .right, controller: fixture.controller)
        XCTAssertEqual(split.target, other)
        XCTAssertTrue(commitBrowserSurfaceDrop(split, controller: fixture.controller))
        XCTAssertEqual(Set(fixture.controller.surfaceTree.roots[focus.workspace.name]?.flatMap(\.surfaces) ?? []),
                       [fixture.page, other, fixture.native.surfaceID])
    }

    func testCenterSwapsLeavesAndSelfDoesNotResolve() throws {
        let fixture = fixture()
        let destination = try resolve(source: fixture.page, target: fixture.native.surfaceID, zone: .middle, controller: fixture.controller)
        let original = fixture.controller.surfaceTree.roots[focus.workspace.name]?.flatMap(\.surfaces)
        XCTAssertTrue(commitBrowserSurfaceDrop(destination, controller: fixture.controller))
        XCTAssertEqual(fixture.controller.surfaceTree.roots[focus.workspace.name]?.flatMap(\.surfaces), original?.reversed().map { $0 })
        let frame = try frame(for: fixture.page, controller: fixture.controller)
        XCTAssertNil(resolveBrowserSurfaceDrop(source: fixture.page, pointer: frame.center, controller: fixture.controller))
    }

    func testDisconnectStaleFrameAndReusedWindowIDCannotCommit() throws {
        let fixture = fixture()
        let destination = try resolve(source: fixture.page, target: fixture.native.surfaceID, zone: .left, controller: fixture.controller)
        let before = fixture.controller.surfaceTree
        fixture.controller.disconnected(fixture.connection)
        XCTAssertFalse(commitBrowserSurfaceDrop(destination, controller: fixture.controller))
        XCTAssertEqual(fixture.controller.surfaceTree, before)

        let next = self.fixture()
        let stale = try resolve(source: next.page, target: next.native.surfaceID, zone: .right, controller: next.controller)
        XCTAssertTrue(next.controller.resizeSurface(next.page, in: focus.workspace, dimension: .width, amount: 40))
        let resized = next.controller.surfaceTree
        XCTAssertFalse(commitBrowserSurfaceDrop(stale, controller: next.controller))
        XCTAssertEqual(next.controller.surfaceTree, resized)
        let recycled = try resolve(source: next.page, target: next.native.surfaceID, zone: .left, controller: next.controller)
        next.native.unbindFromParent()
        _ = TestWindow.new(id: next.native.windowId, parent: focus.workspace.rootTilingContainer)
        XCTAssertFalse(commitBrowserSurfaceDrop(recycled, controller: next.controller))
        XCTAssertEqual(next.controller.surfaceTree, resized)
    }

    func testLegacyOwnerAndDisabledTabsDoNotOfferUnsupportedDrop() throws {
        let fixture = fixture(protocolVersion: 2)
        let target = try frame(for: fixture.native.surfaceID, controller: fixture.controller)
        XCTAssertNil(resolveBrowserSurfaceDrop(source: fixture.page, pointer: target.center, controller: fixture.controller))
        let current = self.fixture()
        config.windowTabs.enabled = false
        let frame = try frame(for: current.native.surfaceID, controller: current.controller)
        let tab = try XCTUnwrap(WindowIntentZoneBuilder.zones(in: frame).first { $0.zone == .tab })
        XCTAssertNil(resolveBrowserSurfaceDrop(source: current.page, pointer: tab.frame.center, controller: current.controller))
    }

    func testCrossWorkspaceMoveCommitsBothOwnersOnlyAfterTargetValidation() throws {
        let fixture = fixture()
        let sourceWorkspace = focus.workspace
        let rect = Rect(topLeftX: 1600, topLeftY: 0, width: 1600, height: 1000)
        let second = TestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Second", rect: rect, visibleRect: rect, isMain: false)
        setMonitorsForTests([mainMonitor, second])
        let destinationWorkspace = Workspace.get(byName: "second")
        XCTAssertTrue(second.setActiveWorkspace(destinationWorkspace))
        XCTAssertTrue(fixture.controller.editOrganization(of: fixture.page, movingTo: Workspace.get(byName: destinationWorkspace.name)) { _ in true })
        let drop = try resolve(source: fixture.native.surfaceID, target: fixture.page, zone: .left, controller: fixture.controller)
        XCTAssertTrue(commitBrowserSurfaceDrop(drop, controller: fixture.controller))
        XCTAssertTrue(fixture.native.nodeWorkspace === destinationWorkspace)
        XCTAssertEqual(fixture.controller.surfaceTree.workspace(of: fixture.native.surfaceID), destinationWorkspace.name)
        XCTAssertEqual(fixture.controller.workspaceName(for: fixture.page), destinationWorkspace.name)
        XCTAssertTrue(fixture.controller.hasSharedLayout(in: sourceWorkspace))
        XCTAssertTrue(fixture.controller.hasSharedLayout(in: destinationWorkspace))
    }

    func testCrossWorkspaceBrowserMovePreservesNativeTargetAndRejectsCrossSwap() throws {
        let fixture = fixture(secondPage: true)
        let other = try XCTUnwrap(fixture.other)
        let sourceWorkspace = focus.workspace
        let rect = Rect(topLeftX: 1600, topLeftY: 0, width: 1600, height: 1000)
        let second = TestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Second", rect: rect, visibleRect: rect, isMain: false)
        setMonitorsForTests([mainMonitor, second])
        let destinationWorkspace = Workspace.get(byName: "second")
        XCTAssertTrue(second.setActiveWorkspace(destinationWorkspace))
        XCTAssertTrue(fixture.controller.editOrganization(of: other, movingTo: Workspace.get(byName: destinationWorkspace.name)) { _ in true })
        let targetFrame = try frame(for: other, controller: fixture.controller)
        let middle = try XCTUnwrap(WindowIntentZoneBuilder.zones(in: targetFrame).first { $0.zone == .middle })
        XCTAssertNil(resolveBrowserSurfaceDrop(source: fixture.page, pointer: middle.frame.center, controller: fixture.controller))
        let drop = try resolve(source: fixture.page, target: other, zone: .bottom, controller: fixture.controller)
        XCTAssertTrue(commitBrowserSurfaceDrop(drop, controller: fixture.controller))
        XCTAssertEqual(fixture.controller.workspaceName(for: fixture.page), destinationWorkspace.name)
        XCTAssertEqual(fixture.controller.surfaceTree.workspace(of: fixture.page), destinationWorkspace.name)
        XCTAssertTrue(fixture.native.nodeWorkspace === sourceWorkspace)
        XCTAssertEqual(fixture.controller.focusCoordinator.target, fixture.page)
    }

    func testUnavailableWorkspaceMemberRejectsCrossMoveBeforeNativeRebinding() throws {
        let fixture = fixture()
        let sourceWorkspace = focus.workspace
        let rect = Rect(topLeftX: 1600, topLeftY: 0, width: 1600, height: 1000)
        let second = TestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Second", rect: rect, visibleRect: rect, isMain: false)
        setMonitorsForTests([mainMonitor, second])
        let destinationWorkspace = Workspace.get(byName: "second")
        XCTAssertTrue(second.setActiveWorkspace(destinationWorkspace))
        XCTAssertTrue(fixture.controller.editOrganization(of: fixture.page, movingTo: Workspace.get(byName: destinationWorkspace.name)) { _ in true })
        let stale = TestWindow.new(id: 9001, parent: destinationWorkspace.rootTilingContainer)
        var tree = fixture.controller.surfaceTree
        tree.reconcile([fixture.page, stale.surfaceID], in: destinationWorkspace.name)
        fixture.controller.restorePlacementSnapshot(.init(tree: tree,
            layoutWorkspaces: [sourceWorkspace.name, destinationWorkspace.name], selected: nil, closedBrowserTabs: []))
        let drop = try resolve(source: fixture.native.surfaceID, target: fixture.page, zone: .left, controller: fixture.controller)
        stale.unbindFromParent()
        let before = fixture.controller.surfaceTree
        XCTAssertFalse(commitBrowserSurfaceDrop(drop, controller: fixture.controller))
        XCTAssertEqual(fixture.controller.surfaceTree, before)
        XCTAssertTrue(fixture.native.nodeWorkspace === sourceWorkspace)
        XCTAssertEqual(fixture.controller.workspaceName(for: fixture.page), destinationWorkspace.name)
    }

    func testRestoredReservationsAllowCrossWorkspaceDropWithoutMovingOrDisplayingThem() throws {
        let fixture = fixture()
        let sourceWorkspace = focus.workspace
        let rect = Rect(topLeftX: 1600, topLeftY: 0, width: 1600, height: 1000)
        let second = TestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Second", rect: rect, visibleRect: rect, isMain: false)
        setMonitorsForTests([mainMonitor, second])
        let destinationWorkspace = Workspace.get(byName: "second")
        XCTAssertTrue(second.setActiveWorkspace(destinationWorkspace))
        XCTAssertTrue(fixture.controller.editOrganization(of: fixture.page, movingTo: Workspace.get(byName: destinationWorkspace.name)) { _ in true })
        let sourceReservation = SurfaceID.nativeWindow(UUID()), targetReservation = SurfaceID.nativeWindow(UUID())
        var tree = fixture.controller.surfaceTree
        tree.reconcile([fixture.native.surfaceID, sourceReservation], in: sourceWorkspace.name)
        tree.reconcile([fixture.page, targetReservation], in: destinationWorkspace.name)
        fixture.controller.restorePlacementSnapshot(.init(tree: tree,
            layoutWorkspaces: [sourceWorkspace.name, destinationWorkspace.name], selected: nil, closedBrowserTabs: []))
        let drop = try resolve(source: fixture.native.surfaceID, target: fixture.page, zone: .left, controller: fixture.controller)
        XCTAssertTrue(commitBrowserSurfaceDrop(drop, controller: fixture.controller))
        XCTAssertTrue(fixture.native.nodeWorkspace === destinationWorkspace)
        XCTAssertEqual(fixture.controller.surfaceTree.workspace(of: sourceReservation), sourceWorkspace.name)
        XCTAssertEqual(fixture.controller.surfaceTree.workspace(of: targetReservation), destinationWorkspace.name)
        XCTAssertTrue(fixture.controller.plannedSurfaces(in: sourceWorkspace).isEmpty)
        XCTAssertEqual(Set(fixture.controller.plannedSurfaces(in: destinationWorkspace).map(\.surfaceID)),
                       [fixture.native.surfaceID, fixture.page])
    }

    private struct Fixture {
        let controller: BrowserWorkspaceController
        let connection: UUID
        let native: TestWindow
        let page: SurfaceID
        let other: SurfaceID?
    }

    private func fixture(secondPage: Bool = false, protocolVersion: Int = 4) -> Fixture {
        let controller = BrowserWorkspaceController(), connection = UUID()
        nextWindowID += 1
        let native = TestWindow.new(id: nextWindowID, parent: focus.workspace.rootTilingContainer)
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let other = secondPage ? SurfaceID.browserTab(profile: UUID(), tab: UUID()) : nil
        let pages = [page] + (other.map { [$0] } ?? [])
        var tree = SurfaceTree(); tree.reconcile([native.surfaceID] + pages, in: focus.workspace.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [focus.workspace.name], selected: nil, closedBrowserTabs: []))
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: pages.map {
            .init(surfaceID: $0, hostID: $0.description, title: "Page", selected: true, hostMinimumSize: .init(width: 160, height: 120))
        }), epoch: UUID(), connection: connection, protocolVersion: protocolVersion)
        return Fixture(controller: controller, connection: connection, native: native, page: page, other: other)
    }

    private func frame(for id: SurfaceID, controller: BrowserWorkspaceController) throws -> Rect {
        let name = try XCTUnwrap(controller.workspaceName(for: id))
        let workspace = try XCTUnwrap(Workspace.existing(byName: name))
        let placement = try XCTUnwrap(controller.plannedSurfaces(in: workspace).first { $0.surfaceID == id && $0.visible })
        return Rect(topLeftX: CGFloat(placement.frame.x), topLeftY: CGFloat(placement.frame.y),
                    width: CGFloat(placement.frame.width), height: CGFloat(placement.frame.height))
    }

    private func resolve(source: SurfaceID, target: SurfaceID, zone: WindowDropZone,
                         controller: BrowserWorkspaceController) throws -> BrowserSurfaceDropDestination {
        let targetFrame = try frame(for: target, controller: controller)
        let zoneFrame = try XCTUnwrap(WindowIntentZoneBuilder.zones(in: targetFrame).first { $0.zone == zone })
        let result = try XCTUnwrap(resolveBrowserSurfaceDrop(source: source,
            pointer: zoneFrame.frame.center, controller: controller))
        XCTAssertEqual(result.target, target)
        XCTAssertEqual(result.zone, zone)
        return result
    }
}
