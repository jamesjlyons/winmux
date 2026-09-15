@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class WorkspaceReorderingTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func makeGroups() -> [Workspace] {
        ["reorder-a", "reorder-b", "reorder-c", "reorder-d"].map { Workspace.get(byName: $0) }
    }

    private func names(_ groups: [Workspace]) -> [String] {
        let ids = Set(groups.map(\.id))
        return orderedWorkspaces(in: workspaceProjectDefaultId).filter { ids.contains($0.id) }.map(\.name)
    }

    func testGroupsMoveBeforeAndAfterTargetsInBothDirections() {
        let groups = makeGroups()
        XCTAssertTrue(reorderWorkspace("reorder-a", relativeTo: "reorder-c", placement: .after))
        XCTAssertEqual(names(groups), ["reorder-b", "reorder-c", "reorder-a", "reorder-d"])
        XCTAssertTrue(reorderWorkspace("reorder-d", relativeTo: "reorder-b", placement: .before))
        XCTAssertEqual(names(groups), ["reorder-d", "reorder-b", "reorder-c", "reorder-a"])
        XCTAssertTrue(reorderWorkspace("reorder-a", relativeTo: "reorder-b", placement: .after))
        XCTAssertEqual(names(groups), ["reorder-d", "reorder-b", "reorder-a", "reorder-c"])
        XCTAssertTrue(reorderWorkspace("reorder-d", relativeTo: "reorder-c", placement: .before))
        XCTAssertEqual(names(groups), ["reorder-b", "reorder-a", "reorder-d", "reorder-c"])
    }

    func testInvalidAndUnchangedDropsPreserveOrder() throws {
        let groups = makeGroups()
        let otherProject = createWorkspaceProject()
        let other = try XCTUnwrap(orderedWorkspaces(in: otherProject.id).first)
        let original = winMuxWorkspaceState.projectsById

        XCTAssertFalse(reorderWorkspace(groups[0].name, relativeTo: groups[0].name, placement: .after))
        XCTAssertFalse(reorderWorkspace(groups[0].name, relativeTo: groups[1].name, placement: .before))
        XCTAssertFalse(reorderWorkspace(groups[1].name, relativeTo: groups[0].name, placement: .after))
        XCTAssertFalse(reorderWorkspace("missing", relativeTo: groups[0].name, placement: .after))
        XCTAssertFalse(reorderWorkspace(groups[0].name, relativeTo: "missing", placement: .before))
        XCTAssertFalse(reorderWorkspace(groups[0].name, relativeTo: other.name, placement: .before))
        XCTAssertEqual(winMuxWorkspaceState.projectsById, original)
    }

    func testReorderingPreservesFocusMembershipAndLabels() throws {
        let groups = makeGroups()
        let window = TestWindow.new(id: 501, parent: groups[0].rootTilingContainer)
        _ = groups[0].focusWorkspace()
        try renameWorkspaceForSidebar(workspaceName: groups[0].name, displayName: "Research")
        let focused = focus.workspace
        let active = mainMonitor.activeWorkspace
        let project = try XCTUnwrap(winMuxWorkspaceState.projectsById[workspaceProjectDefaultId])

        XCTAssertTrue(reorderWorkspace(groups[0].name, relativeTo: groups[3].name, placement: .after))

        XCTAssertTrue(focus.workspace === focused)
        XCTAssertTrue(mainMonitor.activeWorkspace === active)
        XCTAssertTrue(window.nodeWorkspace === groups[0])
        XCTAssertEqual(workspaceDisplayName(groups[0].name), "Research")
        XCTAssertEqual(winMuxWorkspaceState.projectsById[project.id]?.linkedViewportIds, project.linkedViewportIds)
        XCTAssertEqual(Set(winMuxWorkspaceState.projectsById[project.id]?.workspaceOrder ?? []), Set(project.workspaceOrder))
    }

    func testReorderedGroupsSurviveRestartAndNewGroupsAppend() throws {
        let groups = makeGroups()
        reorderWorkspace(groups[3].name, relativeTo: groups[0].name, placement: .before)
        let expected = orderedWorkspaces(in: workspaceProjectDefaultId).map(\.name)
        let data = try JSONEncoder.winMuxDefault.encode(RestartSessionSnapshot.capture())
        setUpWorkspacesForTests()
        restoreRestartMetadata(try JSONDecoder().decode(RestartSessionSnapshot.self, from: data))

        XCTAssertEqual(orderedWorkspaces(in: workspaceProjectDefaultId).map(\.name), expected)
        let newGroup = Workspace.get(byName: "reorder-new")
        XCTAssertEqual(orderedWorkspaces(in: workspaceProjectDefaultId).map(\.name), expected + [newGroup.name])
    }

    private func dragLayout(sourceName: String = "reorder-b") -> WorkspaceSidebarWorkspaceReorderLayout {
        WorkspaceSidebarWorkspaceReorderLayout(items: [
            .init(name: "reorder-a", frame: CGRect(x: 0, y: 0, width: 200, height: 100)),
            .init(name: "reorder-b", frame: CGRect(x: 0, y: 106, width: 200, height: 60)),
            .init(name: "reorder-c", frame: CGRect(x: 0, y: 172, width: 200, height: 160)),
        ], sourceName: sourceName)!
    }

    func testCardsShiftByDraggedHeightAndSpacingInBothDirections() {
        let layout = dragLayout()
        XCTAssertEqual(layout.offset(for: "reorder-a", destinationIndex: 0), 66)
        XCTAssertEqual(layout.offset(for: "reorder-b", destinationIndex: 0), -106)
        XCTAssertEqual(layout.offset(for: "reorder-c", destinationIndex: 0), 0)
        XCTAssertEqual(layout.offset(for: "reorder-a", destinationIndex: 2), 0)
        XCTAssertEqual(layout.offset(for: "reorder-b", destinationIndex: 2), 166)
        XCTAssertEqual(layout.offset(for: "reorder-c", destinationIndex: 2), -66)
        let tallSource = dragLayout(sourceName: "reorder-c")
        XCTAssertEqual(tallSource.offset(for: "reorder-a", destinationIndex: 0), 166)
        XCTAssertEqual(tallSource.offset(for: "reorder-b", destinationIndex: 0), 166)
        XCTAssertEqual(tallSource.offset(for: "reorder-c", destinationIndex: 0), -172)
    }

    func testSnapThresholdHasHysteresisAndClampsAtListEnds() {
        let layout = dragLayout()
        XCTAssertEqual(layout.snapIndex(translation: -90, previousIndex: 1), 1)
        XCTAssertEqual(layout.snapIndex(translation: -91, previousIndex: 1), 0)
        XCTAssertEqual(layout.snapIndex(translation: -84, previousIndex: 0), 0)
        XCTAssertEqual(layout.snapIndex(translation: -81, previousIndex: 0), 1)
        XCTAssertEqual(layout.snapIndex(translation: 120, previousIndex: 1), 1)
        XCTAssertEqual(layout.snapIndex(translation: 121, previousIndex: 1), 2)
        XCTAssertEqual(layout.snapIndex(translation: 113, previousIndex: 2), 2)
        XCTAssertEqual(layout.snapIndex(translation: 111, previousIndex: 2), 1)
        XCTAssertEqual(layout.snapIndex(translation: -10000, previousIndex: 2), 0)
        XCTAssertEqual(layout.snapIndex(translation: 10000, previousIndex: 0), 2)
    }

    func testCardFollowsPointerAndHapticsOnlyFireOnNewSnapPositions() {
        var haptics = 0
        let state = WorkspaceSidebarWorkspaceReorderState(performSnapHaptic: { haptics += 1 })
        let layout = dragLayout()
        func move(_ y: CGFloat, x: CGFloat = 50) {
            state.update(sourceName: "reorder-b", pointer: CGPoint(x: x, y: 120 + y),
                         translation: CGSize(width: 0, height: y), initialLayout: layout)
        }
        move(120)
        XCTAssertEqual(state.offset(for: "reorder-b"), 120)
        XCTAssertEqual(haptics, 0)
        move(121)
        XCTAssertEqual(haptics, 1)
        XCTAssertEqual(state.offset(for: "reorder-c"), -66)
        move(122)
        move(113)
        XCTAssertEqual(haptics, 1)
        move(111)
        XCTAssertEqual(haptics, 2)
        XCTAssertEqual(state.offset(for: "reorder-c"), 0)
        move(111, x: 1000)
        XCTAssertNil(state.target)
        XCTAssertEqual(haptics, 2)
        state.cancel(sourceName: "reorder-b")
        XCTAssertEqual(state.offset(for: "reorder-b"), 0)
        XCTAssertFalse(isWorkspaceSidebarItemDragActive())
    }

    func testReleaseSettlesAtSlotUntilModelCompletes() async {
        let state = WorkspaceSidebarWorkspaceReorderState(performSnapHaptic: {})
        let layout = dragLayout()
        let pointer = CGPoint(x: 50, y: 251)
        let translation = CGSize(width: 0, height: 131)
        state.update(sourceName: "reorder-b", pointer: pointer, translation: translation, initialLayout: layout)
        var action: WorkspaceSidebarAction?
        state.finish(sourceName: "reorder-b", pointer: pointer, translation: translation, reduceMotion: true,
                     actions: WorkspaceSidebarActions(send: { action = $0 }))
        XCTAssertTrue(state.isSettling)
        XCTAssertEqual(state.offset(for: "reorder-b"), 166)
        for _ in 0..<10 where action == nil { await Task.yield() }
        XCTAssertEqual(action, .reorderWorkspace("reorder-b", relativeTo: "reorder-c", placement: .after))
        state.complete(sourceName: "reorder-b")
        XCTAssertNil(state.sourceName)
        XCTAssertFalse(isWorkspaceSidebarItemDragActive())
    }

    func testCancelledDragReleasesActivationLockWithoutChangingOrder() {
        let groups = makeGroups()
        let state = WorkspaceSidebarWorkspaceReorderState()
        let original = names(groups)
        state.update(sourceName: groups[0].name, pointer: CGPoint(x: -10000, y: -10000))
        XCTAssertTrue(isWorkspaceSidebarItemDragActive())
        XCTAssertEqual(state.sourceName, groups[0].name)
        XCTAssertNil(state.target)

        state.cancel(sourceName: groups[1].name)
        XCTAssertTrue(isWorkspaceSidebarItemDragActive())
        state.cancel(sourceName: groups[0].name)
        XCTAssertFalse(isWorkspaceSidebarItemDragActive())
        XCTAssertNil(state.sourceName)
        XCTAssertEqual(names(groups), original)
    }
}
