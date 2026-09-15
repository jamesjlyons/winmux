@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class WorkspaceProjectReorderingTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testProjectsMoveInBothDirectionsIncludingDefault() {
        let first = createWorkspaceProject()
        let second = createWorkspaceProject()

        reorderWorkspaceProject(workspaceProjectDefaultId, to: second.id)
        XCTAssertEqual(workspaceProjects().map(\.id), [first.id, second.id, workspaceProjectDefaultId])

        reorderWorkspaceProject(second.id, to: first.id)
        XCTAssertEqual(workspaceProjects().map(\.id), [second.id, first.id, workspaceProjectDefaultId])
    }

    func testReorderingKeepsSelectionWorkspacesAndProjectMetadata() throws {
        let project = createWorkspaceProject()
        try renameWorkspaceProject(project.id, displayName: "Research")
        config.workspaceSidebar.projectColors[project.id.rawValue] = "#60A5FA"
        let activeWorkspace = try XCTUnwrap(switchWorkspaceProject(project.id, on: mainMonitor))
        let stored = try XCTUnwrap(winMuxWorkspaceState.projectsById[project.id])

        reorderWorkspaceProject(project.id, to: workspaceProjectDefaultId)

        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), project.id)
        XCTAssertTrue(mainMonitor.activeWorkspace === activeWorkspace)
        XCTAssertEqual(winMuxWorkspaceState.projectsById[project.id]?.workspaceOrder, stored.workspaceOrder)
        XCTAssertEqual(winMuxWorkspaceState.projectsById[project.id]?.linkedViewportIds, stored.linkedViewportIds)
        XCTAssertEqual(workspaceProjectName(project.id), "Research")
        XCTAssertEqual(config.workspaceSidebar.projectColors[project.id.rawValue], "#60A5FA")
    }

    func testStaleOrUnchangedDragDoesNotReorderProjects() {
        let project = createWorkspaceProject()
        let original = workspaceProjects()

        reorderWorkspaceProject(project.id, to: project.id)
        reorderWorkspaceProject("deleted", to: project.id)
        reorderWorkspaceProject(project.id, to: "deleted")

        XCTAssertEqual(workspaceProjects(), original)
    }

    func testReorderedProjectsSurviveRestartAndNewProjectsAppend() throws {
        let first = createWorkspaceProject()
        let second = createWorkspaceProject()
        reorderWorkspaceProject(second.id, to: workspaceProjectDefaultId)
        let expectedOrder = [second.id, workspaceProjectDefaultId, first.id]
        let data = try JSONEncoder.winMuxDefault.encode(RestartSessionSnapshot.capture())
        setUpWorkspacesForTests()

        restoreRestartMetadata(try JSONDecoder().decode(RestartSessionSnapshot.self, from: data))

        XCTAssertEqual(workspaceProjects().map(\.id), expectedOrder)
        let newProject = createWorkspaceProject()
        XCTAssertEqual(workspaceProjects().map(\.id), expectedOrder + [newProject.id])
    }

    func testDragChangesPositionAfterCrossingHalfADotAndClampsAtEnds() {
        XCTAssertEqual(workspaceSidebarProjectReorderIndex(sourceIndex: 1, translation: 19, stride: 40, count: 4), 1)
        XCTAssertEqual(workspaceSidebarProjectReorderIndex(sourceIndex: 1, translation: 21, stride: 40, count: 4), 2)
        XCTAssertEqual(workspaceSidebarProjectReorderIndex(sourceIndex: 1, translation: -21, stride: 40, count: 4), 0)
        XCTAssertEqual(workspaceSidebarProjectReorderIndex(sourceIndex: 1, translation: 1000, stride: 40, count: 4), 3)
        XCTAssertEqual(workspaceSidebarProjectReorderIndex(sourceIndex: 1, translation: -1000, stride: 40, count: 4), 0)
        XCTAssertEqual(workspaceSidebarProjectReorderIndex(sourceIndex: 0, translation: 1000, stride: 32, count: 1), 0)
        XCTAssertEqual(workspaceSidebarProjectReorderIndex(sourceIndex: 0, translation: 18, stride: 32, count: 3), 1)
    }
}
