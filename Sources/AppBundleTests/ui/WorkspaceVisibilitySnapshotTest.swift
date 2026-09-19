@testable import AppBundle
import XCTest

@MainActor
final class WorkspaceVisibilitySnapshotTest: XCTestCase {
    func testBatchedVisibilityMatchesOriginalRulesAcrossLifecycleChanges() {
        setUpWorkspacesForTests()
        var workspaces: [Workspace] = []
        for index in 0 ..< 24 {
            let projectId = WorkspaceProjectId("visibility-project-\(index / 8)")
            if winMuxWorkspaceState.projectsById[projectId] == nil {
                winMuxWorkspaceState.registerProject(.init(id: projectId, name: projectId.rawValue, order: index / 8 + 1))
            }
            let workspace = Workspace.get(byName: "visibility-\(index)")
            workspace.assignProject(projectId)
            switch index % 8 {
                case 0: TestWindow.new(id: UInt32(index + 1), parent: workspace.rootTilingContainer)
                case 1:
                    let window = TestWindow.new(id: UInt32(index + 1), parent: workspace.rootTilingContainer)
                    window.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: workspace.name)
                    window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                case 2: config.persistentWorkspaces.append(workspace.name)
                case 3: workspace.lifecycle = .archived
                case 4: workspace.markAsTransientBlank()
                default: break
            }
            workspaces.append(workspace)
        }
        for visibleIndex in [5, 6, 12, 15, 20] {
            XCTAssertTrue(mainMonitor.setActiveWorkspace(workspaces[visibleIndex]))
            let ordered = orderedWorkspacesForPresentation()
            let expected = ordered.filter { workspace in
                !workspace.isArchived && (workspaceHasSidebarVisibleWindows(workspace) || workspace.isVisible ||
                    workspace.isConfiguredPersistent || !workspaceOwnedMinimizedWindows(workspace).isEmpty ||
                    referenceRetainedWorkspace(in: WorkspaceScope(projectId: workspace.projectId)) == workspace.id)
            }
            XCTAssertEqual(userFacingWorkspaces(ordered).map(\.id), expected.map(\.id))
            for project in workspaceProjects() {
                let scope = WorkspaceScope(projectId: project.id)
                XCTAssertEqual(retainedEmptyWorkspaceId(in: scope), referenceRetainedWorkspace(in: scope))
            }
        }
    }

    // Original scalar rule, kept independent of the batched ownership/retention lookups.
    private func referenceRetainedWorkspace(in scope: WorkspaceScope) -> WorkspaceId? {
        let ordered = orderedWorkspaces(in: scope)
        let empty = ordered.filter(\.isOrdinaryEmptySlot).sorted {
            if $0.lifecycle != $1.lifecycle { return $0.lifecycle == .durable }
            return $0 < $1
        }
        guard !empty.isEmpty else { return nil }
        if !ordered.contains(where: workspaceAnchorsEmptySlot) {
            return empty.first(where: \.isVisible)?.id ?? empty.first?.id
        }
        if let visible = empty.first(where: \.isVisible), workspaceHasAdjacentAnchor(visible, in: ordered) {
            return visible.id
        }
        return nil
    }
}
