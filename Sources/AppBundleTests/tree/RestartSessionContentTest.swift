@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class RestartSessionContentTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testContentComparisonIgnoresOnlyCaptureTime() throws {
        let workspace = focus.workspace
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        let baseline = RestartSessionSnapshot.capture(now: Date(timeIntervalSince1970: 1))
        let later = RestartSessionSnapshot.capture(now: Date(timeIntervalSince1970: 2))
        XCTAssertTrue(later.hasSameContent(as: baseline))
        let decoded = try JSONDecoder().decode(RestartSessionSnapshot.self, from: JSONEncoder.winMuxDefault.encode(later))
        XCTAssertTrue(decoded.hasSameContent(as: baseline))

        var differentVersion = later
        differentVersion.version += 1
        XCTAssertFalse(differentVersion.hasSameContent(as: baseline))

        func assertChanged(_ mutate: () -> Void, undo: () -> Void) {
            mutate()
            XCTAssertFalse(RestartSessionSnapshot.capture().hasSameContent(as: baseline))
            undo()
            XCTAssertTrue(RestartSessionSnapshot.capture().hasSameContent(as: baseline))
        }
        assertChanged({ first.isFullscreen = true }, undo: { first.isFullscreen = false })
        assertChanged({ first.noOuterGapsInFullscreen = true }, undo: { first.noOuterGapsInFullscreen = false })
        assertChanged({ first.setWeight(.h, 2) }, undo: { first.setWeight(.h, 1) })
        assertChanged({ workspace.rootTilingContainer.layout = .tabGroup }, undo: { workspace.rootTilingContainer.layout = .tiles })
        assertChanged({ first.markAsMostRecentChild() }, undo: { workspace.rootTilingContainer.children.last?.markAsMostRecentChild() })
        assertChanged({ workspace.markAsAutomaticallyNamed() }, undo: { workspace.restoreNamingStyle(.explicit) })
        let project = try XCTUnwrap(winMuxWorkspaceState.projectsById[workspace.projectId])
        assertChanged({
            winMuxWorkspaceState.projectsById[project.id] = WorkspaceProject(
                id: project.id, name: "Renamed", order: project.order,
                workspaceOrder: project.workspaceOrder, linkedViewportIds: project.linkedViewportIds)
        }, undo: {
            winMuxWorkspaceState.projectsById[project.id] = project
        })
    }

    func testContentComparisonDetectsIdentityFrameFocusAndBootChanges() throws {
        let workspace = focus.workspace
        TestWindow.new(id: 1, parent: workspace, rect: Rect(topLeftX: 10, topLeftY: 20, width: 400, height: 300))
        let baseline = RestartSessionSnapshot.capture()
        let window = try XCTUnwrap(baseline.windows?.first)
        let variants = [
            RestartSessionSnapshot(savedAt: baseline.savedAt, bootSession: "different-boot", world: baseline.world,
                                   windows: baseline.windows, projects: baseline.projects, focusedWindowId: baseline.focusedWindowId, focusedWorkspace: baseline.focusedWorkspace),
            RestartSessionSnapshot(savedAt: baseline.savedAt, bootSession: baseline.bootSession, world: baseline.world,
                                   windows: baseline.windows, projects: baseline.projects, focusedWindowId: 99, focusedWorkspace: baseline.focusedWorkspace),
            RestartSessionSnapshot(savedAt: baseline.savedAt, bootSession: baseline.bootSession, world: baseline.world,
                                   windows: baseline.windows, projects: baseline.projects, focusedWindowId: baseline.focusedWindowId, focusedWorkspace: "other-workspace"),
            RestartSessionSnapshot(savedAt: baseline.savedAt, bootSession: baseline.bootSession, world: baseline.world,
                                   windows: [RestartWindow(id: window.id, identity: .init(pid: 99, bundleId: "other-app", launchDate: .now), floatingFrame: window.floatingFrame)],
                                   projects: baseline.projects, focusedWindowId: baseline.focusedWindowId, focusedWorkspace: baseline.focusedWorkspace),
            RestartSessionSnapshot(savedAt: baseline.savedAt, bootSession: baseline.bootSession, world: baseline.world,
                                   windows: [RestartWindow(id: window.id, identity: window.identity, floatingFrame: .zero)],
                                   projects: baseline.projects, focusedWindowId: baseline.focusedWindowId, focusedWorkspace: baseline.focusedWorkspace),
        ]
        for variant in variants { XCTAssertFalse(variant.hasSameContent(as: baseline)) }
    }
}
