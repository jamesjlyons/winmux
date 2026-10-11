@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor final class PinnedViewCombinationTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.newItemPlacement = .newView
        TestApp.shared.bundlePath = "/Missing/Test.app"
    }

    override func tearDown() async throws {
        config.newItemPlacement = .tile
        TestApp.shared.bundlePath = nil
    }

    func testAddAppToPinnedAppRetainsPinIdentityAndRestoresEveryLayout() throws {
        for layout in [SurfaceContainerLayout.horizontal, .vertical, .stack] {
            let (c, windows) = fixture()
            let target = windows[0], incoming = windows[1], unrelated = windows[2]
            let regular = try XCTUnwrap(incoming.nodeWorkspace)
            XCTAssertTrue(c.pinSurface(target.surfaceID))
            let pin = try XCTUnwrap(c.pinnedViews.first)
            let order = c.pinShelves
            XCTAssertTrue(c.combineViews(incoming.surfaceID, with: target.surfaceID, layout: layout, before: true))
            XCTAssertTrue(target.nodeWorkspace === incoming.nodeWorkspace)
            XCTAssertTrue(unrelated.nodeWorkspace === regular)
            let combined = try XCTUnwrap(c.pinnedViews.first)
            XCTAssertEqual(combined.id, pin.id)
            XCTAssertEqual(combined.workspaceName, pin.workspaceName)
            XCTAssertEqual(combined.kind, .group)
            XCTAssertEqual(combined.memberIDs.count, 2)
            XCTAssertEqual(Set(combined.bindings.values), [target.surfaceID, incoming.surfaceID])
            XCTAssertEqual(c.pinShelves, order)
            XCTAssertEqual(c.pinTiles(in: pin.workspaceName).first?.groupMembers.count, 2)
            let group = try XCTUnwrap(c.surfaceTree.containingGroup(of: target.surfaceID))
            XCTAssertEqual(c.surfaceTree.layouts[group], layout)
            let snapshot = try XCTUnwrap(c.capturePlacementSnapshot()).validated()
            let restored = BrowserWorkspaceController()
            restored.restorePlacementSnapshot(snapshot)
            XCTAssertEqual(restored.pinnedViews.first?.id, pin.id)
            XCTAssertEqual(restored.pinnedViews.first?.memberIDs, combined.memberIDs)
            XCTAssertEqual(restored.surfaceTree.group(group), c.surfaceTree.group(group))
            for window in windows { window.unbindFromParent() }
        }
    }

    func testCombiningFromPinnedAppKeepsThePinAndRequestedSplitOrder() throws {
        let (c, windows) = fixture()
        XCTAssertTrue(c.pinSurface(windows[0].surfaceID))
        let pin = try XCTUnwrap(c.pinnedViews.first)
        XCTAssertTrue(c.combineViews(windows[0].surfaceID, with: windows[1].surfaceID, layout: .horizontal, before: true))
        XCTAssertEqual(windows[1].nodeWorkspace?.name, pin.workspaceName)
        XCTAssertEqual(c.surfaceTree.roots[pin.workspaceName]?.flatMap(\.surfaces), [windows[0].surfaceID, windows[1].surfaceID])
        XCTAssertEqual(c.pinnedViews.first?.id, pin.id)
    }

    func testAddWholeGroupPreservesNestedLayoutAndMemberIdentities() throws {
        let (c, windows) = fixture()
        XCTAssertTrue(c.combineViews(windows[2].surfaceID, with: windows[1].surfaceID, layout: .stack))
        let group = try XCTUnwrap(c.surfaceTree.containingGroup(of: windows[1].surfaceID))
        let original = try XCTUnwrap(c.surfaceTree.group(group))
        c.reconcileSavedViews()
        let memberIDs = windows.map { c.savedMemberID(for: $0.surfaceID) }
        XCTAssertTrue(c.pinSurface(windows[0].surfaceID))
        let pin = try XCTUnwrap(c.pinnedViews.first)
        XCTAssertTrue(c.combineGroupViews(group, with: windows[0].surfaceID, layout: .vertical, before: false))
        XCTAssertEqual(c.surfaceTree.group(group), original)
        XCTAssertEqual(c.surfaceTree.layouts[group], .stack)
        XCTAssertTrue(windows.allSatisfy { $0.nodeWorkspace?.name == pin.workspaceName })
        XCTAssertEqual(c.pinnedViews.first?.memberIDs.count, 3)
        XCTAssertEqual(windows.map { c.savedMemberID(for: $0.surfaceID) }, memberIDs)
        XCTAssertNoThrow(try c.capturePlacementSnapshot()?.validated())
    }

    func testCombiningPinsKeepsDestinationAndRemovesEmptySourcePin() throws {
        let (c, windows) = fixture()
        XCTAssertTrue(c.pinSurface(windows[0].surfaceID))
        XCTAssertTrue(c.pinSurface(windows[1].surfaceID))
        let destination = try XCTUnwrap(c.pinnedViews.first { $0.workspaceName == windows[0].nodeWorkspace?.name })
        let source = try XCTUnwrap(c.pinnedViews.first { $0.id != destination.id })
        XCTAssertTrue(c.combineViews(windows[1].surfaceID, with: windows[0].surfaceID, layout: .stack))
        XCTAssertEqual(c.pinnedViews.map(\.id), [destination.id])
        XCTAssertEqual(Set(c.pinnedViews[0].memberIDs), Set(destination.memberIDs + source.memberIDs))
        XCTAssertFalse(c.pinShelves.flatMap(\.desktopOrder).contains(source.id))
        XCTAssertFalse(Workspace.existing(byName: source.workspaceName)?.isPinnedGroup ?? false)
        XCTAssertNoThrow(try c.capturePlacementSnapshot()?.validated())
    }

    func testMissingLaunchDescriptorRejectsWholeGroupWithoutMovingOwners() throws {
        let (c, windows) = fixture()
        XCTAssertTrue(c.combineViews(windows[2].surfaceID, with: windows[1].surfaceID, layout: .stack))
        let group = try XCTUnwrap(c.surfaceTree.containingGroup(of: windows[1].surfaceID))
        XCTAssertTrue(c.pinSurface(windows[0].surfaceID))
        let source = windows[1].nodeWorkspace
        let tree = c.surfaceTree, views = c.savedViews, shelves = c.pinShelves
        TestApp.shared.bundlePath = nil
        XCTAssertFalse(c.combineGroupViews(group, with: windows[0].surfaceID, layout: .horizontal, before: false))
        XCTAssertEqual(c.surfaceTree, tree)
        XCTAssertEqual(c.savedViews, views)
        XCTAssertEqual(c.pinShelves, shelves)
        XCTAssertTrue(windows[1].nodeWorkspace === source && windows[2].nodeWorkspace === source)
    }

    func testMixedSelectionGroupsIntoPinRegardlessOfSelectionOrder() throws {
        let (c, windows) = fixture()
        XCTAssertTrue(c.pinSurface(windows[0].surfaceID))
        let pin = try XCTUnwrap(c.pinnedViews.first)
        let panes = [windows[1], windows[0]].map { SurfacePane.surface($0.surfaceID) }
        XCTAssertTrue(canGroupSelectedTabs(panes, controller: c))
        XCTAssertTrue(performTabBatchAction(panes, action: .group(.horizontal), controller: c))
        XCTAssertEqual(c.pinnedViews.first?.id, pin.id)
        XCTAssertEqual(windows[1].nodeWorkspace?.name, pin.workspaceName)
        XCTAssertEqual(c.pinnedViews.first?.members.count, 2)
        XCTAssertNoThrow(try c.capturePlacementSnapshot()?.validated())
    }

    func testBrowserTabAddedToPinRetainsClosedSlotAndRestoresWithNewIdentity() throws {
        let (c, windows) = fixture()
        let connection = UUID(), epoch = UUID(), profile = UUID()
        let page = SurfaceID.browserTab(profile: profile, tab: UUID())
        func record(_ id: SurfaceID) -> BrowserTabRecord {
            .init(surfaceID: id, hostID: id.description, title: "Docs", selected: false, url: "https://example.test/docs")
        }
        var tree = c.surfaceTree
        tree.reconcile(windows.map(\.surfaceID) + [page], in: focus.workspace.name)
        c.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        c.connected(connection, processID: -1) { _, reply in reply(.issued) }
        c.received(.init(revision: 1, full: true, tabs: [record(page)]), epoch: epoch, connection: connection, protocolVersion: 5)
        XCTAssertTrue(c.pinSurface(windows[0].surfaceID))
        let pin = try XCTUnwrap(c.pinnedViews.first)
        XCTAssertTrue(c.combineViews(page, with: windows[0].surfaceID, layout: .horizontal))
        let member = try XCTUnwrap(c.sidebarPin(for: page))
        XCTAssertEqual(member.url, "https://example.test/docs")
        XCTAssertEqual(member.workspaceName, pin.workspaceName)
        let group = try XCTUnwrap(c.surfaceTree.containingGroup(of: page))
        c.received(.init(revision: 2, full: true, tabs: []), epoch: epoch, connection: connection, protocolVersion: 5)
        XCTAssertEqual(c.pinnedViews.first?.memberIDs.count, 2)
        XCTAssertEqual(c.pinnedViews.first?.layout.flatMap(\.members).count, 2)
        let snapshot = try XCTUnwrap(c.capturePlacementSnapshot()).validated()
        let restored = BrowserWorkspaceController()
        restored.restorePlacementSnapshot(snapshot)
        XCTAssertEqual(restored.pinnedViews.first?.memberIDs.count, 2)
        let replacement = SurfaceID.browserTab(profile: profile, tab: UUID())
        c.received(.init(revision: 3, full: true, tabs: [record(replacement)]), epoch: epoch, connection: connection, protocolVersion: 5)
        XCTAssertTrue(c.adoptPinnedSurface(replacement, into: pin.workspaceName))
        let index = try XCTUnwrap(c.browserSidebarPins.firstIndex { $0.id == member.id })
        c.browserSidebarPins[index].surfaceID = replacement
        c.restorePinnedViewLayout(containing: member.id)
        XCTAssertEqual(c.surfaceTree.group(group)?.surfaces, [windows[0].surfaceID, replacement])
        XCTAssertNoThrow(try c.capturePlacementSnapshot()?.validated())
        c.disconnected(connection)
    }

    private func fixture() -> (BrowserWorkspaceController, [TestWindow]) {
        let controller = BrowserWorkspaceController(), workspace = focus.workspace
        let windows = (601...603).map { TestWindow.new(id: UInt32($0), parent: workspace.rootTilingContainer) }
        var tree = SurfaceTree()
        tree.reconcile(windows.map(\.surfaceID), in: workspace.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        return (controller, windows)
    }
}
