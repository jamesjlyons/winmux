@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor final class PinnedViewGroupsTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.newItemPlacement = .newView
        TestApp.shared.bundlePath = "/Missing/Test.app"
    }
    override func tearDown() async throws { config.newItemPlacement = .tile; TestApp.shared.bundlePath = nil }

    func testPinWholeSplitKeepsNestedLayoutWeightsAndSingleDesktopSelection() throws {
        let c = BrowserWorkspaceController(), source = focus.workspace
        let windows = (301...304).map { TestWindow.new(id: UInt32($0), parent: source.rootTilingContainer) }
        var tree = SurfaceTree(); tree.reconcile(windows.map(\.surfaceID), in: source.name)
        XCTAssertTrue(tree.group(windows[1].surfaceID, with: windows[0].surfaceID, layout: .stack))
        XCTAssertTrue(tree.split(windows[2].surfaceID, beside: windows[0].surfaceID, layout: .horizontal, before: false))
        let node = try XCTUnwrap(tree.roots[source.name]?.first)
        guard case .group(let id, _) = node else { return XCTFail("Expected split") }
        tree.setWeights(["group:" + (tree.containingGroup(of: windows[0].surfaceID)!).uuidString.lowercased(): 3,
                         windows[2].surfaceID.description: 2])
        c.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [source.name], selected: nil, closedBrowserTabs: []))
        XCTAssertTrue(c.pinSurfaceGroup(id))
        let pins = try XCTUnwrap(windows[0].nodeWorkspace)
        let desktopID = try XCTUnwrap(c.pinnedViews.first?.id)
        XCTAssertEqual(c.surfaceTree.group(id), node)
        XCTAssertEqual(c.surfaceTree.layouts, tree.layouts)
        XCTAssertEqual(c.surfaceTree.weights, tree.weights)
        XCTAssertTrue(c.pinSurface(windows[0].surfaceID), "Re-pinning a member is a no-op")
        XCTAssertEqual(c.nativeAppSidebarPins.count, 3, "Two windows of one app must not replace each other")
        XCTAssertEqual(c.pinTiles(in: pins.name).count, 1)
        XCTAssertEqual(c.pinTiles(in: pins.name).first?.groupMembers.count, 3)
        XCTAssertTrue(c.pinSurface(windows[3].surfaceID))
        let single = try XCTUnwrap(c.nativeAppSidebarPins.first { $0.surfaceID == windows[3].surfaceID })
        let singleID = try XCTUnwrap(c.pinnedViews.first { $0.memberIDs.contains(single.id) }?.id)
        let singleWorkspace = try XCTUnwrap(windows[3].nodeWorkspace)
        XCTAssertFalse(singleWorkspace === pins)
        XCTAssertEqual(c.pinTilesByWorkspace().values.flatMap { $0 }.count, 2)
        XCTAssertEqual(c.selectPin(singleID), .issued)
        let singlePlan = c.plannedSurfaces(in: singleWorkspace).filter(\.visible)
        XCTAssertEqual(singlePlan.map(\.surfaceID), [windows[3].surfaceID])
        let fullFrame = try XCTUnwrap(singlePlan.first?.frame)
        XCTAssertEqual(c.selectPin(desktopID), .issued)
        let groupPlan = c.plannedSurfaces(in: pins).filter(\.visible)
        XCTAssertEqual(groupPlan.count, 2)
        let layout = c.plannedLayout(in: pins)
        XCTAssertEqual(layout.frames[.group(id)]?.width, fullFrame.width)
        XCTAssertEqual(layout.stacks.filter(\.visible).count, 1)
        XCTAssertEqual(groupPlan.map { $0.frame.width }.reduce(0, +) + 2 * c.stackChrome(in: pins).sideInset + c.layoutGaps(in: pins).horizontal, fullFrame.width)
        XCTAssertFalse(groupPlan.contains { $0.surfaceID == windows[3].surfaceID })
        let snapshot = try XCTUnwrap(c.capturePlacementSnapshot()).validated()
        let restored = BrowserWorkspaceController(); restored.restorePlacementSnapshot(snapshot)
        XCTAssertEqual(restored.surfaceTree.group(id), node)
        XCTAssertEqual(restored.pinTilesByWorkspace().values.flatMap { $0 }.count, 2)
        let otherSpace = createWorkspaceProject()
        XCTAssertTrue(restored.movePin(desktopID, to: otherSpace.id))
        XCTAssertEqual(restored.surfaceTree.group(id), node)
        XCTAssertEqual(restored.pinTiles(in: singleWorkspace.name).map(\.id), [singleID])
        XCTAssertNoThrow(try restored.capturePlacementSnapshot()?.validated())
        XCTAssertTrue(restored.movePin(desktopID, to: source.projectId))
        XCTAssertTrue(restored.unpin(desktopID))
        XCTAssertEqual(restored.surfaceTree.group(id), node)
        XCTAssertFalse(windows[0].nodeWorkspace?.isPinnedGroup ?? true)
        XCTAssertTrue(windows[3].nodeWorkspace === singleWorkspace)
        XCTAssertEqual(restored.pinTiles(in: singleWorkspace.name).map(\.id), [singleID])
        XCTAssertNoThrow(try restored.capturePlacementSnapshot()?.validated())
    }

    func testPinWholeViewAndSeparateMemberMakesIndependentPins() throws {
        let c = BrowserWorkspaceController(), source = focus.workspace
        let a = TestWindow.new(id: 311, parent: source.rootTilingContainer)
        let b = TestWindow.new(id: 312, parent: source.rootTilingContainer)
        var tree = SurfaceTree(); tree.reconcile([a.surfaceID, b.surfaceID], in: source.name)
        c.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [source.name], selected: nil, closedBrowserTabs: []))
        XCTAssertTrue(c.pinWorkspaceView(source.name))
        let pins = try XCTUnwrap(a.nodeWorkspace)
        XCTAssertEqual(c.pinTiles(in: pins.name).first?.groupMembers.count, 2)
        XCTAssertTrue(c.separateView(b.surfaceID))
        let separated = try XCTUnwrap(b.nodeWorkspace)
        XCTAssertFalse(separated === a.nodeWorkspace)
        XCTAssertEqual(c.pinTilesByWorkspace().values.flatMap { $0 }.count, 2)
        XCTAssertEqual(c.select(b.surfaceID), .issued)
        XCTAssertEqual(c.plannedSurfaces(in: separated).filter(\.visible).map(\.surfaceID), [b.surfaceID])
        XCTAssertNoThrow(try c.capturePlacementSnapshot()?.validated())
    }

    func testClosedBrowserGroupRetainsTemplateAndRebindsNewIdentity() throws {
        let c = BrowserWorkspaceController(), source = focus.workspace, connection = UUID(), epoch = UUID(), profile = UUID()
        c.usesSurfaceTree = true
        c.connected(connection, processID: -1, send: { _, reply in reply(.issued) })
        let a = SurfaceID.browserTab(profile: profile, tab: UUID()), b = SurfaceID.browserTab(profile: profile, tab: UUID())
        func record(_ id: SurfaceID) -> BrowserTabRecord { .init(surfaceID: id, hostID: id.description, title: "Page", selected: false, url: "https://example.test") }
        c.received(.init(revision: 1, full: true, tabs: [record(a), record(b)]), epoch: epoch, connection: connection, protocolVersion: 5)
        var tree = SurfaceTree(); tree.reconcile([a, b], in: source.name)
        c.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [source.name], selected: nil, closedBrowserTabs: []))
        XCTAssertTrue(c.surfaceTree.group(b, with: a, layout: .vertical))
        let group = try XCTUnwrap(c.surfaceTree.containingGroup(of: a))
        XCTAssertTrue(c.pinSurfaceGroup(group))
        let pin = try XCTUnwrap(c.sidebarPin(for: b))
        let pinned = try XCTUnwrap(Workspace.existing(byName: pin.workspaceName))
        c.received(.init(revision: 2, full: true, tabs: [record(a)]), epoch: epoch, connection: connection, protocolVersion: 5)
        XCTAssertEqual(c.pinTiles(in: pinned.name).count, 1)
        XCTAssertEqual(c.pinTiles(in: pinned.name).first?.groupMembers.count, 2)
        XCTAssertNoThrow(try c.capturePlacementSnapshot()?.validated())
        let replacement = SurfaceID.browserTab(profile: profile, tab: UUID())
        c.received(.init(revision: 3, full: true, tabs: [record(a), record(replacement)]), epoch: epoch, connection: connection, protocolVersion: 5)
        _ = c.adoptPinnedSurface(replacement, into: pinned.name)
        let index = try XCTUnwrap(c.browserSidebarPins.firstIndex { $0.id == pin.id })
        c.browserSidebarPins[index].surfaceID = replacement
        c.restorePinnedViewLayout(containing: pin.id)
        XCTAssertEqual(c.surfaceTree.group(group)?.surfaces, [a, replacement])
        XCTAssertEqual(c.surfaceTree.layouts[group], .vertical)
        XCTAssertNoThrow(try c.capturePlacementSnapshot()?.validated())
        c.disconnected(connection)
    }

    func testFailedGroupPinLeavesAllMembersUnchanged() throws {
        let c = BrowserWorkspaceController(), source = focus.workspace
        let a = TestWindow.new(id: 321, parent: source.rootTilingContainer)
        let b = TestWindow.new(id: 322, parent: source.rootTilingContainer)
        var tree = SurfaceTree(); tree.reconcile([a.surfaceID, b.surfaceID], in: source.name)
        tree.group(b.surfaceID, with: a.surfaceID)
        c.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        TestApp.shared.bundlePath = nil
        XCTAssertFalse(c.pinSurfaceGroup(try XCTUnwrap(tree.containingGroup(of: a.surfaceID))))
        XCTAssertEqual(c.surfaceTree, tree)
        XCTAssertTrue(a.nodeWorkspace === source && b.nodeWorkspace === source)
        XCTAssertTrue(c.nativeAppSidebarPins.isEmpty)
    }
}
