@testable import AppBundle
import WorkspaceCore
import XCTest

@MainActor final class TabBatchActionsTest: XCTestCase {
    func testMixedGroupingDoesNotAbsorbUnselectedSiblingOrChangeNativeParent() throws {
        let f = try BrowserProfileMovesTest.Fixture(); defer { f.stop() }
        let a = f.add(), b = f.add()
        let native = TestWindow.new(id: 9801, parent: f.source.rootTilingContainer)
        f.controller.reconcileSharedOrganization()
        let parent = native.parent
        XCTAssertTrue(performTabBatchAction([.surface(a), .surface(native.surfaceID)], action: .group(.stack), controller: f.controller))
        let group = try XCTUnwrap(f.controller.surfaceTree.stack(containing: a))
        XCTAssertEqual(f.controller.surfaceTree.group(group)?.surfaces, [a, native.surfaceID])
        XCTAssertFalse(f.controller.surfaceTree.group(group)!.surfaces.contains(b))
        XCTAssertTrue(native.parent === parent)
    }

    func testMoveStagesEntireBatchBeforeCommittingDestinationProfile() throws {
        let f = try BrowserProfileMovesTest.Fixture(); defer { f.stop() }
        let a = f.add(url: "https://example.test/a"), b = f.add(url: "https://example.test/b"), untouched = f.add()
        XCTAssertTrue(performTabBatchAction([.surface(b), .surface(a)], action: .move(f.destination.name), controller: f.controller))
        XCTAssertEqual(f.requests.count, 2)
        XCTAssertEqual(f.controller.workspaceName(for: a), f.source.name)
        XCTAssertEqual(f.controller.workspaceName(for: b), f.source.name)
        let firstReplacement = f.replacement(0)
        XCTAssertEqual(f.controller.workspaceName(for: a), f.source.name)
        XCTAssertTrue(f.closed.isEmpty)
        let secondReplacement = f.replacement(1)
        let newB = f.requests[0].url == "https://example.test/b" ? firstReplacement : secondReplacement
        let newA = f.requests[0].url == "https://example.test/a" ? firstReplacement : secondReplacement
        XCTAssertEqual(f.controller.workspaceName(for: newB), f.destination.name)
        XCTAssertEqual(f.controller.workspaceName(for: newA), f.destination.name)
        XCTAssertEqual(f.controller.surfaceTree.roots[f.destination.name]?.flatMap(\.surfaces), [newB, newA])
        XCTAssertEqual(f.controller.workspaceName(for: untouched), f.source.name)
        XCTAssertEqual(f.closed, [a, b])
    }

    func testStaleMemberRejectsWholeBatchBeforeAnyAction() throws {
        let f = try BrowserProfileMovesTest.Fixture(); defer { f.stop() }
        let a = f.add(), missing = SurfaceID.nativeWindow(UUID())
        let panes: [SurfacePane] = [.surface(a), .surface(missing)], before = f.controller.surfaceTree
        XCTAssertFalse(performTabBatchAction(panes, action: .move(f.destination.name), controller: f.controller))
        XCTAssertFalse(performTabBatchAction(panes, action: .group(.stack), controller: f.controller))
        XCTAssertFalse(performTabBatchAction(panes, action: .close, controller: f.controller))
        XCTAssertEqual(f.controller.surfaceTree, before)
        XCTAssertTrue(f.requests.isEmpty); XCTAssertTrue(f.closed.isEmpty)
    }

    func testFailedProfileCopyLeavesAllOriginalTabsInPlace() throws {
        let f = try BrowserProfileMovesTest.Fixture(); defer { f.stop() }
        let a = f.add(), b = f.add()
        let before = f.controller.surfaceTree
        XCTAssertTrue(performTabBatchAction([.surface(a), .surface(b)], action: .move(f.destination.name), controller: f.controller))
        let copy = f.replacement(0)
        f.replies[1](.unavailable, nil)
        // Chromium owns closure; acknowledge disposal of the provisional copy.
        f.records.removeAll { $0.surfaceID == copy }
        f.publish()
        XCTAssertEqual(f.controller.workspaceName(for: a), f.source.name)
        XCTAssertEqual(f.controller.workspaceName(for: b), f.source.name)
        XCTAssertEqual(f.controller.surfaceTree.roots[f.source.name], before.roots[f.source.name])
        XCTAssertFalse(f.closed.contains(a)); XCTAssertFalse(f.closed.contains(b))
        XCTAssertTrue(f.closed.contains(copy))
    }

    func testMoveToNewViewCreatesOneDestinationForAllSelectedTabs() throws {
        let f = try BrowserProfileMovesTest.Fixture(); defer { f.stop() }
        let a = f.add(), b = f.add()
        let oldNames = Set(Workspace.all.map(\.name))
        XCTAssertTrue(performTabBatchAction([.surface(a), .surface(b)],
            action: .newView(f.source.projectId, monitorScopeID: workspaceSidebarDefaultScopeId), controller: f.controller))
        let newNames = Set(Workspace.all.map(\.name)).subtracting(oldNames)
        XCTAssertEqual(newNames.count, 1)
        let destination = try XCTUnwrap(newNames.first)
        XCTAssertEqual(f.controller.workspaceName(for: a), destination)
        XCTAssertEqual(f.controller.workspaceName(for: b), destination)
        XCTAssertEqual(f.controller.surfaceTree.roots[destination]?.flatMap(\.surfaces), [a, b])
    }

    func testCloseNestedPaneResolvesAllMembersWithoutClosingOtherTabs() throws {
        let f = try BrowserProfileMovesTest.Fixture(); defer { f.stop() }
        let a = f.add(), b = f.add(), c = f.add(), untouched = f.add()
        XCTAssertTrue(performTabBatchAction([.surface(a), .surface(b)], action: .group(.horizontal), controller: f.controller))
        let group = try XCTUnwrap(f.controller.surfaceTree.containingGroup(of: a))
        XCTAssertTrue(performTabBatchAction([.group(group), .surface(c)], action: .close, controller: f.controller))
        XCTAssertEqual(f.closed, [a, b, c]); XCTAssertFalse(f.closed.contains(untouched))
    }

    func testGroupingAcrossSpacesIsDisabledWithoutStartingProfileMoves() throws {
        let f = try BrowserProfileMovesTest.Fixture(); defer { f.stop() }
        let a = f.add(), b = f.add()
        XCTAssertTrue(moveSidebarSurface(b, to: f.destination, controller: f.controller))
        let replacement = f.replacement()
        let panes: [SurfacePane] = [.surface(a), .surface(replacement)]
        let before = f.controller.surfaceTree, requests = f.requests.count
        XCTAssertFalse(canGroupSelectedTabs(panes, controller: f.controller))
        XCTAssertFalse(performTabBatchAction(panes, action: .group(.stack), controller: f.controller))
        XCTAssertEqual(f.controller.surfaceTree, before); XCTAssertEqual(f.requests.count, requests)
    }

    func testGroupingReversedRangeShowsDestinationAndRetainsFocusedMember() throws {
        let f = try BrowserProfileMovesTest.Fixture(); defer { f.stop() }
        let a = f.add(), b = f.add()
        let later = Workspace.get(byName: "later-view")
        XCTAssertTrue(f.controller.arrangeSelectedTabs([.surface(b)], in: later))
        XCTAssertEqual(f.controller.select(b), .issued)
        XCTAssertEqual(focus.workspace, later)
        XCTAssertTrue(performTabBatchAction([.surface(a), .surface(b)], action: .group(.stack), controller: f.controller))
        XCTAssertEqual(focus.workspace, f.source)
        XCTAssertEqual(f.controller.focusCoordinator.target, b)
        let stack = try XCTUnwrap(f.controller.surfaceTree.stack(containing: b))
        XCTAssertEqual(f.controller.surfaceTree.activeSurfaces[stack], b)
    }

    func testLegacyNativeGroupContainsOnlySelectedWindows() throws {
        setUpWorkspacesForTests()
        let controller = BrowserWorkspaceController()
        let root = focus.workspace.rootTilingContainer
        root.layout = .tabGroup
        let a = TestWindow.new(id: 9811, parent: root), b = TestWindow.new(id: 9812, parent: root)
        let c = TestWindow.new(id: 9813, parent: root)
        XCTAssertTrue(performTabBatchAction([.surface(c.surfaceID), .surface(a.surfaceID)], action: .group(.stack), controller: controller))
        let group = try XCTUnwrap(c.nearestWindowTabGroup)
        XCTAssertEqual(group.allLeafWindowsRecursive.map(\.windowId), [c.windowId, a.windowId])
        XCTAssertFalse(b.nearestWindowTabGroup === group)
        XCTAssertTrue(performTabBatchAction([.surface(c.surfaceID), .surface(a.surfaceID)], action: .separate, controller: controller))
        XCTAssertNil(c.nearestWindowTabGroup); XCTAssertNil(a.nearestWindowTabGroup)
    }
}
