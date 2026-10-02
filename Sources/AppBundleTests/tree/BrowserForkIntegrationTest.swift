@testable import AppBundle
import AppKit
import Common
import WorkspaceCore
import XCTest

@MainActor final class BrowserForkIntegrationTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testWholeMixedSubtreeMovesToFreshGroupAndKeepsSourceFocus() throws {
        let fixture = try mixedFixture()
        let destination = Workspace.get(byName: "New Group")
        XCTAssertNil(fixture.controller.surfaceTree.roots[destination.name])
        let before = fixture.controller.surfaceTree
        let subtree = try XCTUnwrap(before.group(fixture.group))
        XCTAssertEqual(fixture.controller.select(fixture.pages[1]), .issued)
        XCTAssertTrue(fixture.controller.canMoveGroup(fixture.group))
        XCTAssertTrue(fixture.controller.moveGroup(fixture.group, to: destination))
        XCTAssertTrue(fixture.native.nodeWorkspace === destination)
        XCTAssertTrue(fixture.remaining.nodeWorkspace === fixture.source)
        XCTAssertEqual(fixture.controller.surfaceTree.roots[destination.name], [subtree])
        XCTAssertEqual(fixture.controller.surfaceTree.layouts, before.layouts)
        XCTAssertEqual(fixture.controller.surfaceTree.weights, before.weights)
        XCTAssertEqual(fixture.controller.workspaceName(forGroup: fixture.group), destination.name)
        XCTAssertEqual(fixture.controller.focusCoordinator.target, fixture.remaining.surfaceID)
        XCTAssertEqual(fixture.controller.surfaceTree.activeSurfaces[fixture.stack], fixture.pages[1])
        XCTAssertTrue(fixture.controller.hasMixedLayout(in: fixture.source))
        XCTAssertTrue(fixture.controller.hasMixedLayout(in: destination))
        for page in fixture.pages { XCTAssertEqual(fixture.controller.workspaceName(for: page), destination.name) }
        let after = try XCTUnwrap(fixture.controller.capturePlacementSnapshot())
        XCTAssertEqual(try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: JSONEncoder().encode(after)), after)
    }

    func testMovingLastLiveGroupClearsBrowserFocusAndRetainsMissingNativeReservation() throws {
        let fixture = try mixedFixture()
        let saved = try XCTUnwrap(fixture.controller.capturePlacementSnapshot())
        fixture.remaining.unbindFromParent()
        fixture.controller.restorePlacementSnapshot(saved)
        XCTAssertEqual(fixture.controller.select(fixture.pages[1]), .issued)
        let destination = Workspace.get(byName: "Moved last live group")
        XCTAssertTrue(fixture.controller.moveGroup(fixture.group, to: destination))
        XCTAssertNil(fixture.controller.focusCoordinator.target)
        XCTAssertTrue(focus.workspace === fixture.source)
        XCTAssertEqual(fixture.controller.surfaceTree.roots[fixture.source.name], [.surface(fixture.remaining.surfaceID)])
        XCTAssertEqual(fixture.controller.capturePlacementSnapshot()?.selected, nil)
    }

    func testUnprojectedDestinationPreservesItsExistingNativeSplit() throws {
        let fixture = try mixedFixture()
        let destination = Workspace.get(byName: "Existing native group")
        let split = TilingContainer.newVTiles(parent: destination.rootTilingContainer, adaptiveWeight: 600, index: INDEX_BIND_LAST)
        let first = TestWindow.new(id: 720, parent: split, adaptiveWeight: 250)
        let second = TestWindow.new(id: 721, parent: split, adaptiveWeight: 450)
        XCTAssertNil(fixture.controller.surfaceTree.roots[destination.name])
        XCTAssertTrue(fixture.controller.moveGroup(fixture.group, to: destination))
        let adoptedSplit = try XCTUnwrap(fixture.controller.surfaceTree.containingGroup(of: first.surfaceID))
        XCTAssertEqual(fixture.controller.surfaceTree.group(adoptedSplit)?.surfaces, [first.surfaceID, second.surfaceID])
        XCTAssertEqual(fixture.controller.sidebarGroupLayout(adoptedSplit), .vertical)
        XCTAssertEqual(fixture.controller.surfaceTree.weights[first.surfaceID.description], 250)
        XCTAssertEqual(fixture.controller.surfaceTree.weights[second.surfaceID.description], 450)
        XCTAssertTrue(first.parent === split && second.parent === split)
    }

    func testUnavailableLegacyAndRecycledOwnersCannotPartiallyMoveGroup() throws {
        for unavailable in ["disconnect", "legacy", "recycled"] {
            let fixture = try mixedFixture(protocolVersion: unavailable == "legacy" ? 2 : 4)
            let destination = Workspace.get(byName: "destination-" + unavailable)
            if unavailable == "disconnect" { fixture.controller.disconnected(fixture.connection) }
            if unavailable == "recycled" {
                fixture.native.unbindFromParent()
                _ = TestWindow.new(id: fixture.native.windowId, parent: fixture.source.rootTilingContainer)
            }
            let before = fixture.controller.surfaceTree
            XCTAssertFalse(fixture.controller.canMoveGroup(fixture.group))
            XCTAssertFalse(fixture.controller.moveGroup(fixture.group, to: destination))
            XCTAssertEqual(fixture.controller.surfaceTree, before)
            XCTAssertTrue(destination.allLeafWindowsRecursive.isEmpty)
            for page in fixture.pages { XCTAssertEqual(fixture.controller.workspaceName(for: page), fixture.source.name) }
        }
    }

    func testFloatingAndTemporaryNativeStatesStayOutsideSharedTiles() async throws {
        let source = focus.workspace
        let tiled = TestWindow.new(id: 700, parent: source.rootTilingContainer)
        let floating = TestWindow.new(id: 701, parent: source, rect: Rect(topLeftX: 100, topLeftY: 120, width: 350, height: 260))
        let controller = BrowserWorkspaceController()
        controller.usesSurfaceTree = true
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID()), connection = UUID()
        connect(controller, connection: connection, pages: [page])
        let tiledRow = await row(tiled), floatingRow = await row(floating)
        let items = controller.organizedRows(native: [tiledRow, floatingRow], in: source.name)
        XCTAssertNil(controller.surfaceTree.workspace(of: floating.surfaceID))
        guard case .window(let retained) = items.last?.kind else { return XCTFail("Floating row lost native behavior") }
        XCTAssertEqual(retained.surfaceID, floating.surfaceID)
        XCTAssertEqual(controller.plannedSurfaces(in: source).map(\.surfaceID), [tiled.surfaceID, page])
        guard case .surface(let projected) = items.first?.kind else { return XCTFail("Missing native surface") }
        XCTAssertEqual(projected.appBundleId, tiled.app.rawAppBundleId)
        for state in ["minimized", "native-fullscreen", "winmux-fullscreen"] {
            tiled.isFullscreen = state == "winmux-fullscreen"
            tiled.recordObservedNativeState(fullscreen: state == "native-fullscreen", minimized: state == "minimized", token: tiled.nativeStateObservationToken())
            _ = controller.organizedRows(native: [tiledRow, floatingRow], in: source.name)
            XCTAssertEqual(controller.surfaceTree.workspace(of: tiled.surfaceID), source.name)
            XCTAssertFalse(controller.plannedSurfaces(in: source).contains { $0.surfaceID == tiled.surfaceID })
        }
        tiled.isFullscreen = false
        tiled.recordObservedNativeState(fullscreen: false, minimized: false, token: tiled.nativeStateObservationToken())
        _ = controller.organizedRows(native: [tiledRow, floatingRow], in: source.name)
        XCTAssertTrue(controller.plannedSurfaces(in: source).contains { $0.surfaceID == tiled.surfaceID })
    }

    func testNativeAdoptionPreservesNestedSplitWeightsAndStackSelection() async throws {
        let source = focus.workspace
        let first = TestWindow.new(id: 710, parent: source.rootTilingContainer, adaptiveWeight: 200)
        let split = TilingContainer.newVTiles(parent: source.rootTilingContainer, adaptiveWeight: 600, index: INDEX_BIND_LAST)
        let second = TestWindow.new(id: 711, parent: split, adaptiveWeight: 250)
        let stack = TilingContainer(parent: split, adaptiveWeight: 350, .h, .tabGroup, index: INDEX_BIND_LAST)
        let third = TestWindow.new(id: 712, parent: stack)
        let fourth = TestWindow.new(id: 713, parent: stack)
        XCTAssertTrue(fourth.focusWindow())
        let controller = BrowserWorkspaceController(); controller.usesSurfaceTree = true
        let native = await buildWorkspaceSidebarItems(from: source.rootTilingContainer, workspaceName: source.name, currentFocus: focus)
        let items = controller.organizedRows(native: native, in: source.name)
        let vertical = try XCTUnwrap(controller.surfaceTree.containingGroup(of: second.surfaceID))
        let tabStack = try XCTUnwrap(controller.surfaceTree.containingGroup(of: third.surfaceID))
        XCTAssertNotEqual(vertical, tabStack)
        XCTAssertEqual(controller.sidebarGroupLayout(vertical), .vertical)
        XCTAssertEqual(controller.sidebarGroupLayout(tabStack), .stack)
        XCTAssertEqual(controller.surfaceTree.activeSurfaces[tabStack], fourth.surfaceID)
        XCTAssertEqual(controller.surfaceTree.weights[first.surfaceID.description], 200)
        XCTAssertEqual(controller.surfaceTree.weights["group:" + vertical.uuidString.lowercased()], 600)
        XCTAssertEqual(items.flatMap(\.surfaceIDs), [first.surfaceID, second.surfaceID, third.surfaceID, fourth.surfaceID])
        XCTAssertEqual(items.count, 3, "Split containers stay flat in the sidebar")
        let before = controller.surfaceTree
        _ = controller.organizedRows(native: native, in: source.name)
        XCTAssertEqual(controller.surfaceTree, before)
        XCTAssertTrue(controller.editOrganization(of: third.surfaceID) { $0.setLayout(containing: third.surfaceID, to: .vertical) })
        XCTAssertEqual(controller.organizedRows(native: native, in: source.name).count, 4, "Changing layout must publish a changed sidebar snapshot")
    }

    func testFreshInventoryUsesCurrentAutomaticGroupAndRetainsPagesOnRestore() throws {
        let source = createBlankWorkspace(projectId: workspaceProjectDefaultId, monitor: mainMonitor)
        XCTAssertTrue(source.focusWorkspace())
        XCTAssertEqual(source.namingStyle, .automatic)
        let pages = [SurfaceID.browserTab(profile: UUID(), tab: UUID()), SurfaceID.browserTab(profile: UUID(), tab: UUID())]
        let controller = BrowserWorkspaceController(foregroundProcessID: { -1 }); controller.usesSurfaceTree = true
        let connection = UUID()
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: pages.enumerated().map { offset, page in
            .init(surfaceID: page, hostID: "host-\(offset)", title: "Page", selected: true, focused: offset == 1)
        }), epoch: UUID(), connection: connection, protocolVersion: 4)
        _ = controller.organizedRows(native: [], in: source.name)
        XCTAssertEqual(controller.focusCoordinator.target, pages[1])
        XCTAssertEqual(controller.rows(in: source.name).flatMap(\.surfaceIDs), pages.sorted { $0.description < $1.description })
        XCTAssertTrue(controller.rows(in: "Browser").isEmpty)
        XCTAssertTrue(controller.rows(in: "Recovered").isEmpty)
        let saved = try XCTUnwrap(controller.capturePlacementSnapshot())
        let restored = BrowserWorkspaceController(); restored.restorePlacementSnapshot(saved)
        XCTAssertEqual(restored.capturePlacementSnapshot(), saved)
        connect(restored, connection: UUID(), pages: pages)
        XCTAssertEqual(restored.surfaceTree.workspace(of: pages[0]), source.name)
        XCTAssertEqual(restored.surfaceTree.workspace(of: pages[1]), source.name)
        XCTAssertEqual(restored.capturePlacementSnapshot()?.selected, pages[1])
    }

    private struct Fixture {
        let controller: BrowserWorkspaceController
        let connection: UUID
        let source: Workspace
        let native: TestWindow
        let remaining: TestWindow
        let pages: [SurfaceID]
        let group: UUID
        let stack: UUID
    }

    private func mixedFixture(protocolVersion: Int = 4) throws -> Fixture {
        let source = focus.workspace
        let native = TestWindow.new(id: UInt32(TestApp.shared.windows.count + 800), parent: source.rootTilingContainer)
        let remaining = TestWindow.new(id: UInt32(TestApp.shared.windows.count + 800), parent: source.rootTilingContainer)
        let pages = [SurfaceID.browserTab(profile: UUID(), tab: UUID()), SurfaceID.browserTab(profile: UUID(), tab: UUID())]
        var tree = SurfaceTree(); tree.reconcile([native.surfaceID] + pages + [remaining.surfaceID], in: source.name)
        tree.group(pages[0], with: native.surfaceID, layout: .horizontal)
        tree.group(pages[1], with: pages[0])
        let group = try XCTUnwrap(tree.containingGroup(of: native.surfaceID))
        let stack = try XCTUnwrap(tree.containingGroup(of: pages[1]))
        tree.select(pages[1])
        tree.setWeights([native.surfaceID.description: 320, pages[0].description: 220, pages[1].description: 240])
        let controller = BrowserWorkspaceController()
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [source.name], selected: nil, closedBrowserTabs: []))
        let connection = UUID(); connect(controller, connection: connection, pages: pages, protocolVersion: protocolVersion)
        return .init(controller: controller, connection: connection, source: source, native: native, remaining: remaining,
                     pages: pages, group: group, stack: stack)
    }

    private func connect(_ controller: BrowserWorkspaceController, connection: UUID, pages: [SurfaceID], protocolVersion: Int = 4) {
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: pages.enumerated().map { offset, page in
            .init(surfaceID: page, hostID: "host-\(offset)", title: "Page", selected: true)
        }), epoch: UUID(), connection: connection, protocolVersion: protocolVersion)
    }

    private func row(_ window: Window) async -> WorkspaceSidebarItemViewModel {
        .init(kind: .window(await makeWorkspaceSidebarWindowViewModel(for: window, workspaceName: window.nodeWorkspace!.name, currentFocus: focus)))
    }
}
