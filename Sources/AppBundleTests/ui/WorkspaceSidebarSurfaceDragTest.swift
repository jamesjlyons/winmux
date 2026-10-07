import AppKit
@testable import AppBundle
import WorkspaceCore
import XCTest

@MainActor
final class WorkspaceSidebarSurfaceDragTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testPanelExpansionStaysLockedDuringSidebarGestureWithoutNativeDragOrDropPreview() {
        let panel = WorkspaceSidebarPanel.shared
        let previousPreview = TrayMenuModel.shared.workspaceSidebarDropPreview
        TrayMenuModel.shared.workspaceSidebarDropPreview = nil
        resetWorkspaceSidebarItemDrag()
        defer {
            resetWorkspaceSidebarItemDrag()
            TrayMenuModel.shared.workspaceSidebarDropPreview = previousPreview
        }
        XCTAssertFalse(panel.shouldLockExpansionForSidebarDrag())
        // The shared row gesture locks the panel before a typed callback finds
        // an actionable destination; it never starts a native mouse session.
        beginWorkspaceSidebarItemDrag()
        XCTAssertEqual(getCurrentMouseManipulationKind(), .none)
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview)
        XCTAssertTrue(panel.shouldLockExpansionForSidebarDrag())
        endWorkspaceSidebarItemDrag()
        XCTAssertFalse(panel.shouldLockExpansionForSidebarDrag())
    }

    func testGroupPayloadKeepsItsUUIDAndRejectsInvalidNumericOwners() {
        let group = UUID()
        let payload = WorkspaceSidebarDragPayload.surfaceGroup(group)
        XCTAssertEqual(WorkspaceSidebarDragPayload(encodedValue: payload.encodedValue), payload)
        XCTAssertNil(WorkspaceSidebarDragPayload(encodedValue: "surface-group:42"))
        XCTAssertNil(WorkspaceSidebarDragPayload(encodedValue: "surface:browser:42"))
    }

    func testCancellationCannotRestartOrCommitUntilPointerRelease() {
        let subject = WorkspaceSidebarSurfaceDragSubject.surface(.browserTab(profile: UUID(), tab: UUID()))
        var state = WorkspaceSidebarSurfaceDragState()
        XCTAssertTrue(state.begin(subject))
        state.cancel()
        XCTAssertNil(state.subject)
        XCTAssertFalse(state.begin(subject))
        XCTAssertFalse(state.finish(subject))
        state.releasePointer()
        XCTAssertTrue(state.begin(subject))
        XCTAssertTrue(state.finish(subject))
        XCTAssertNil(state.subject)
    }

    func testAnotherSubjectCannotTakeOverOrFinishAnActiveGesture() {
        let original = WorkspaceSidebarSurfaceDragSubject.group(UUID())
        let other = WorkspaceSidebarSurfaceDragSubject.surface(.nativeWindow(UUID()))
        var state = WorkspaceSidebarSurfaceDragState()
        XCTAssertTrue(state.begin(original))
        XCTAssertTrue(state.begin(original))
        XCTAssertFalse(state.begin(other))
        XCTAssertFalse(state.finish(other))
        XCTAssertEqual(state.subject, original)
        XCTAssertTrue(state.finish(original))
        XCTAssertFalse(state.finish(original))
    }

    func testMixedGroupPreviewUsesTheEntireTreeEvenWhenPresentationIsFiltered() async throws {
        let controller = BrowserWorkspaceController()
        controller.usesSurfaceTree = true
        let native = TestWindow.new(id: 8021, parent: focus.workspace.rootTilingContainer)
        let tab = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let connection = UUID()
        controller.connected(connection, processID: -1, sendLayout: { _, reply in reply(.issued) }) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [record(tab)]), epoch: UUID(), connection: connection, protocolVersion: 3)
        let nativeRow = WorkspaceSidebarItemViewModel(kind: .window(await makeWorkspaceSidebarWindowViewModel(
            for: native, workspaceName: focus.workspace.name, currentFocus: focus)))
        _ = controller.organizedRows(native: [nativeRow], in: focus.workspace.name)
        XCTAssertEqual(controller.select(native.surfaceID), .issued)
        controller.organize(tab, groupWithSelection: true)
        let group = try XCTUnwrap(controller.surfaceTree.containingGroup(of: tab))
        let model = TrayMenuModel()
        model.workspaceSidebarWorkspaces = [.init(name: focus.workspace.name, projectId: workspaceProjectDefaultId,
            displayName: "Source", sidebarLabel: "", isGeneratedName: false, monitorScopeId: "test", monitorName: nil,
            isFocused: true, isVisible: true, items: [.init(kind: .surface(.init(surfaceID: tab, title: "Web search match",
                appName: "WinMux Browser", isFocused: true, appBundleId: "browser.fixture")))])]
        let preview = try XCTUnwrap(workspaceSidebarSurfaceSourcePreview(.group(group), controller: controller, viewModel: model))
        XCTAssertNil(preview.sourceWindowId)
        XCTAssertEqual(preview.sourceSubject, .group(group))
        XCTAssertEqual(preview.windowCount, 2)
        XCTAssertTrue(preview.isTabGroup)
        XCTAssertEqual(preview.tabItems.count, 2)
        XCTAssertEqual(preview.tabItems.last?.title, "Web search match")
        XCTAssertEqual(preview.tabItems.last?.appBundleIdentifier, "browser.fixture")
        XCTAssertFalse(isActionableWorkspaceSidebarSurfaceDrop(.group(group), target: .workspace(focus.workspace.name), controller: controller))
        _ = Workspace.get(byName: "destination")
        XCTAssertTrue(isActionableWorkspaceSidebarSurfaceDrop(.group(group), target: .workspace("destination"), controller: controller))
        XCTAssertFalse(isActionableWorkspaceSidebarSurfaceDrop(.group(group), target: .workspace("missing"), controller: controller))
        XCTAssertFalse(isActionableWorkspaceSidebarSurfaceDrop(.group(group), target: .newWorkspace(projectId: "missing", monitorScopeId: "test"), controller: controller))
        controller.disconnected(connection)
        XCTAssertNil(workspaceSidebarSurfaceSourcePreview(.group(group), controller: controller, viewModel: model))
        XCTAssertFalse(isActionableWorkspaceSidebarSurfaceDrop(.group(group), target: .workspace("destination"), controller: controller))
    }

    func testLeafPreviewRetainsProfileQualifiedIdentityWithoutNativeWindowNumber() throws {
        let controller = BrowserWorkspaceController()
        controller.usesSurfaceTree = true
        let tab = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let connection = UUID()
        controller.connected(connection, processID: -1, sendLayout: { _, reply in reply(.issued) }) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [record(tab)]), epoch: UUID(), connection: connection, protocolVersion: 3)
        _ = controller.organizedRows(native: [], in: focus.workspace.name)
        let preview = try XCTUnwrap(workspaceSidebarSurfaceSourcePreview(.surface(tab), controller: controller, viewModel: TrayMenuModel()))
        XCTAssertEqual(preview.sourceSubject, .surface(tab))
        XCTAssertNil(preview.sourceWindowId)
        XCTAssertEqual(preview.label, "Reference page")
        XCTAssertEqual(preview.windowCount, 1)
        XCTAssertFalse(preview.isTabGroup)
        XCTAssertTrue(preview.tabItems.isEmpty)
    }

    func testRejectedNewGroupMoveDoesNotLeaveAnEmptyDestination() throws {
        let fixture = try unavailableSourceReservationFixture()
        let workspacesBefore = Set(Workspace.all.map(\.id))
        let treeBefore = fixture.controller.surfaceTree
        XCTAssertTrue(fixture.controller.canMoveGroup(fixture.group), "The moved stack itself has live owners")
        XCTAssertFalse(moveSidebarSurfaceGroupToNewWorkspace(fixture.group, projectId: workspaceProjectDefaultId,
            monitor: mainMonitor, controller: fixture.controller))
        XCTAssertEqual(Set(Workspace.all.map(\.id)), workspacesBefore)
        XCTAssertEqual(fixture.controller.surfaceTree, treeBefore)
        XCTAssertTrue(fixture.windows.allSatisfy { $0.nodeWorkspace === focus.workspace })
    }

    func testRejectedNewGroupMovePreservesAnExistingRetainedEmptyGroup() throws {
        let fixture = try unavailableSourceReservationFixture()
        let retained = createBlankWorkspace(projectId: workspaceProjectDefaultId, monitor: mainMonitor)
        let workspacesBefore = Set(Workspace.all.map(\.id))
        XCTAssertFalse(moveSidebarSurfaceGroupToNewWorkspace(fixture.group, projectId: workspaceProjectDefaultId,
            monitor: mainMonitor, controller: fixture.controller))
        XCTAssertEqual(Set(Workspace.all.map(\.id)), workspacesBefore)
        XCTAssertTrue(Workspace.existing(byName: retained.name) === retained)
        XCTAssertTrue(retained.allLeafWindowsRecursive.isEmpty)
    }

    func testMovingSelectedNativeSidebarLeafKeepsFocusOnTheSourceGroup() async throws {
        let source = focus.workspace
        let moved = TestWindow.new(id: 8041, parent: source.rootTilingContainer)
        let remaining = TestWindow.new(id: 8042, parent: source.rootTilingContainer)
        let controller = BrowserWorkspaceController.shared
        controller.restorePlacementSnapshot(.init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        defer {
            controller.nativeSelectionChanged(nil)
            controller.restorePlacementSnapshot(.init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
            controller.usesSurfaceTree = false
        }
        controller.reconcileSharedOrganization()
        XCTAssertEqual(controller.select(moved.surfaceID), .issued)
        let destination = Workspace.get(byName: "Native move destination")
        XCTAssertTrue(moveSidebarSurface(moved.surfaceID, to: destination))
        XCTAssertTrue(moved.nodeWorkspace === destination)
        XCTAssertTrue(remaining.nodeWorkspace === source)
        XCTAssertEqual(controller.surfaceTree.workspace(of: moved.surfaceID), destination.name)
        XCTAssertEqual(controller.focusCoordinator.target, remaining.surfaceID)
        XCTAssertTrue(focus.workspace === source)
        XCTAssertTrue(focus.windowOrNil === remaining)
    }

    private func unavailableSourceReservationFixture() throws -> (controller: BrowserWorkspaceController, group: UUID, windows: [TestWindow]) {
        let source = focus.workspace
        let first = TestWindow.new(id: 8031, parent: source.rootTilingContainer)
        let second = TestWindow.new(id: 8032, parent: source.rootTilingContainer)
        let disconnectedPage = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var tree = SurfaceTree()
        tree.reconcile([first.surfaceID, second.surfaceID, disconnectedPage], in: source.name)
        XCTAssertTrue(tree.group(second.surfaceID, with: first.surfaceID))
        let group = try XCTUnwrap(tree.containingGroup(of: first.surfaceID))
        let controller = BrowserWorkspaceController()
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [source.name], selected: nil, closedBrowserTabs: []))
        return (controller, group, [first, second])
    }

    private func record(_ id: SurfaceID) -> BrowserTabRecord {
        .init(surfaceID: id, hostID: "host:fixture", title: "Reference page", selected: true, hostWindowID: 6021)
    }
}
