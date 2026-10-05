@testable import AppBundle
import XCTest
import WorkspaceCore

@MainActor
final class WindowMoveMenuTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testViewsDestinationsExcludeStandaloneAppsAndTabsButKeepCombinedAndEmptyNamedGroups() throws {
        let controller = BrowserWorkspaceController.shared
        controller.usesSurfaceTree = true
        config.workspaceInteractionMode = .views
        defer {
            controller.restorePlacementSnapshot(.init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
            controller.usesSurfaceTree = false
            config.workspaceInteractionMode = .tiling
        }
        let singleApp = Workspace.get(byName: "single-app")
        let window = TestWindow.new(id: 82005, parent: singleApp.rootTilingContainer)
        let singleTab = Workspace.get(byName: "single-tab")
        let tab = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let combined = Workspace.get(byName: "combined")
        let first = TestWindow.new(id: 82006, parent: combined.rootTilingContainer)
        let second = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let empty = Workspace.get(byName: "empty-group")
        var tree = SurfaceTree()
        tree.reconcile([window.surfaceID], in: singleApp.name)
        tree.reconcile([tab], in: singleTab.name)
        tree.reconcile([first.surfaceID, second], in: combined.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))

        let groups = Set(windowMoveMenuDestinations().flatMap(\.groups).map(\.id))
        XCTAssertFalse(groups.contains(singleApp.name))
        XCTAssertFalse(groups.contains(singleTab.name))
        XCTAssertTrue(groups.contains(combined.name))
        XCTAssertTrue(groups.contains(empty.name))

        config.workspaceInteractionMode = .tiling
        let traditional = Set(windowMoveMenuDestinations().flatMap(\.groups).map(\.id))
        XCTAssertTrue(traditional.contains(singleApp.name))
        XCTAssertTrue(traditional.contains(singleTab.name))
    }

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
