@testable import AppBundle
import XCTest

@MainActor
final class WindowMoveMenuTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testDestinationsIncludeInactiveAndEmptySpacesInSavedOrderWithoutSidebar() throws {
        config.workspaceSidebar.enabled = false
        let source = focus.workspace
        let project = createWorkspaceProject()
        try renameWorkspaceProject(project.id, displayName: "Research")
        let first = try XCTUnwrap(orderedWorkspaces(in: project.id).first)
        let second = Workspace.get(byName: "move-destination")
        second.assignProject(project.id)
        try renameWorkspaceForSidebar(workspaceName: first.name, displayName: "Reading")
        try renameWorkspaceForSidebar(workspaceName: second.name, displayName: "Notes")
        XCTAssertTrue(reorderWorkspace(second.name, relativeTo: first.name, placement: .before))
        reorderWorkspaceProject(project.id, to: workspaceProjectDefaultId)

        let destinations = windowMoveMenuDestinations()

        XCTAssertEqual(destinations.first?.id, project.id)
        XCTAssertEqual(destinations.first?.title, "Research")
        XCTAssertEqual(destinations.first?.groups.map(\.id), [second.name, first.name])
        XCTAssertEqual(destinations.first?.groups.map(\.title), ["Notes", "Reading"])
        XCTAssertTrue(focus.workspace === source)
        XCTAssertTrue(first.isEffectivelyEmpty)
        XCTAssertTrue(second.isEffectivelyEmpty)
    }

    func testMovingOneTabToAnotherSpaceLeavesOtherTabsAndFocusInSource() throws {
        let source = focus.workspace
        let project = createWorkspaceProject()
        let destination = try XCTUnwrap(orderedWorkspaces(in: project.id).first)
        let group = TilingContainer(parent: source.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, .v, .tabGroup, index: INDEX_BIND_LAST)
        let selected = TestWindow.new(id: 82001, parent: group)
        let remaining = TestWindow.new(id: 82002, parent: group)
        let another = TestWindow.new(id: 82003, parent: group)

        applySidebarWorkspaceMove(
            sourceNode: dragSubjectNode(for: selected, subject: .window),
            sourceWindow: selected,
            targetWorkspace: destination,
        )

        XCTAssertTrue(selected.nodeWorkspace === destination)
        XCTAssertTrue(remaining.parent === group)
        XCTAssertTrue(another.parent === group)
        XCTAssertTrue(remaining.nodeWorkspace === source)
        XCTAssertTrue(focus.workspace === source)
        XCTAssertEqual(group.children.count, 2)
    }

    func testMovingFloatingWindowToAnotherGroupKeepsItFloating() {
        let source = focus.workspace
        let destination = Workspace.get(byName: "floating-destination")
        let window = TestWindow.new(id: 82004, parent: source)

        applySidebarWorkspaceMove(sourceNode: window, sourceWindow: window, targetWorkspace: destination)

        XCTAssertTrue(window.parent === destination)
        XCTAssertTrue(window.isFloating)
        XCTAssertTrue(focus.workspace === source)
    }
}
