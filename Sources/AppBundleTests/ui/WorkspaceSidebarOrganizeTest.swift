import AppKit
import Common
import SwiftUI
@testable import AppBundle
import XCTest

@MainActor
final class WorkspaceSidebarOrganizeTest: XCTestCase {
    func testDragAndDropUseQueuedEventLocationInsteadOfGlobalCursor() throws {
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 500, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        let tracker = MousePointerTracker.shared
        let previousSample = tracker.currentSample
        defer { tracker.note(point: previousSample.point, timestamp: previousSample.timestamp) }
        let location = CGPoint(x: 400, y: 200)
        let expected = normalizeAppKitScreenPoint(window.convertPoint(toScreen: location))
        for type in [NSEvent.EventType.leftMouseDragged, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: 123,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            ))
            tracker.note(point: .zero)
            XCTAssertEqual(currentWorkspaceSidebarDragPointer(event: event), expected)
            XCTAssertEqual(tracker.currentSample.timestamp, 123)
        }
    }

    func testSingleSpaceKeepsNormalWidthAndManySpacesFitDisplay() {
        let single = WorkspaceSidebarOrganizeLayout(expandedWidth: 280, projectCount: 1, availableWidth: 1440)
        XCTAssertEqual(single.columnWidth, 256)
        XCTAssertEqual(single.visibleWidth, 280)
        let two = WorkspaceSidebarOrganizeLayout(expandedWidth: 280, projectCount: 2, availableWidth: 1440)
        XCTAssertEqual(two.visibleWidth, 544)
        let many = WorkspaceSidebarOrganizeLayout(expandedWidth: 280, projectCount: 10, availableWidth: 1440)
        XCTAssertEqual(many.visibleWidth, 1440)
        XCTAssertEqual(many.contentWidth, 2656)
        XCTAssertEqual(many.columnWidth, single.columnWidth)
    }

    func testResizeAndSpaceDeletionRecomputeNaturalWidth() {
        let before = WorkspaceSidebarOrganizeLayout(expandedWidth: 280, projectCount: 3, availableWidth: 1440)
        let resized = WorkspaceSidebarOrganizeLayout(expandedWidth: 300, projectCount: 3, availableWidth: 1440)
        let deleted = WorkspaceSidebarOrganizeLayout(expandedWidth: 300, projectCount: 2, availableWidth: 1440)
        XCTAssertEqual(resized.visibleWidth - before.visibleWidth, 60)
        XCTAssertEqual(resized.visibleWidth - deleted.visibleWidth, 284)
        XCTAssertEqual(WorkspaceSidebarOrganizeLayout(expandedWidth: 280, projectCount: 0, availableWidth: 200).visibleWidth, 200)
    }

    func testEdgeScrollingStopsOutsideViewportAndAcceleratesTowardEdge() {
        XCTAssertEqual(workspaceSidebarOrganizeScrollStep(pointerX: 300, viewportWidth: 600), 0)
        XCTAssertEqual(workspaceSidebarOrganizeScrollStep(pointerX: -1, viewportWidth: 600), 0)
        XCTAssertEqual(workspaceSidebarOrganizeScrollStep(pointerX: 601, viewportWidth: 600), 0)
        XCTAssertEqual(workspaceSidebarOrganizeScrollStep(pointerX: 18, viewportWidth: 600), -5)
        XCTAssertEqual(workspaceSidebarOrganizeScrollStep(pointerX: 582, viewportWidth: 600), 5)
        XCTAssertEqual(workspaceSidebarOrganizeScrollStep(pointerX: 600, viewportWidth: 600), 10)
    }

    func testClippingKeepsPartiallyVisibleTargetsWithOriginalReorderGeometry() {
        let target = WorkspaceSidebarDropTargetFrame(kind: .workspace("first"), frame: CGRect(x: -230, y: 60, width: 256, height: 200))
        let viewport = CGRect(x: 0, y: 40, width: 500, height: 600)
        let result = clippedWorkspaceSidebarDropTargets([target], to: viewport)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.frame, target.frame)
        XCTAssertEqual(result.first?.clipFrame, viewport)
    }

    func testNestedClippingExcludesHiddenColumnsAndVerticallyHiddenGroups() {
        let target = WorkspaceSidebarDropTargetFrame(kind: .workspace("target"), frame: CGRect(x: 240, y: 20, width: 256, height: 200))
        let column = CGRect(x: 240, y: 60, width: 256, height: 500)
        let panel = CGRect(x: 0, y: 0, width: 300, height: 700)
        let clipped = clippedWorkspaceSidebarDropTargets(clippedWorkspaceSidebarDropTargets([target], to: column), to: panel)
        XCTAssertEqual(clipped.first?.clipFrame, CGRect(x: 240, y: 60, width: 60, height: 500))
        XCTAssertTrue(clippedWorkspaceSidebarDropTargets([target], to: CGRect(x: 0, y: 0, width: 200, height: 700)).isEmpty)
        XCTAssertTrue(clippedWorkspaceSidebarDropTargets([target], to: CGRect(x: 200, y: 300, width: 400, height: 400)).isEmpty)
    }

    func testOrganizeModeIsPanelLocalAndIncludedInSnapshot() {
        setUpWorkspacesForTests()
        let panel = WorkspaceSidebarPanel.shared
        let oldMode = panel.viewModel.workspaceSidebarBrowseMode
        defer { panel.viewModel.workspaceSidebarBrowseMode = oldMode }
        panel.viewModel.workspaceSidebarBrowseMode = .organize
        panel.syncModelFromShared()
        XCTAssertEqual(workspaceSidebarSnapshot(from: panel.viewModel).browseMode, .organize)
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarBrowseMode, .activeProject)
        panel.resetBrowseMode()
        XCTAssertEqual(workspaceSidebarSnapshot(from: panel.viewModel).browseMode, .activeProject)
    }

    func testMenuAndSearchExpansionKeepAllOrganizeColumnsVisible() {
        setUpWorkspacesForTests()
        _ = createWorkspaceProject()
        _ = createWorkspaceProject()
        let panel = WorkspaceSidebarPanel.shared
        let oldProjects = panel.viewModel.workspaceSidebarProjects
        let oldMode = panel.viewModel.workspaceSidebarBrowseMode
        let oldWidth = panel.viewModel.workspaceSidebarVisibleWidth
        let oldExpanded = panel.viewModel.isWorkspaceSidebarExpanded
        defer {
            panel.cancelExpansionWork()
            panel.viewModel.workspaceSidebarProjects = oldProjects
            panel.viewModel.workspaceSidebarBrowseMode = oldMode
            panel.viewModel.workspaceSidebarVisibleWidth = oldWidth
            panel.viewModel.isWorkspaceSidebarExpanded = oldExpanded
        }
        panel.viewModel.workspaceSidebarProjects = buildWorkspaceSidebarProjectViewModels()
        panel.viewModel.workspaceSidebarBrowseMode = .organize
        let expected = panel.expandedPresentationWidth
        panel.expandSidebar(to: CGFloat(config.workspaceSidebar.width))
        XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, expected)
        XCTAssertEqual(panel.viewModel.workspaceSidebarBrowseMode, .organize)
    }

    func testOrganizeSnapshotIncludesEmptySpacesAndMovesDoNotActivateDestination() async {
        setUpWorkspacesForTests()
        let source = focus.workspace
        let second = createWorkspaceProject()
        let third = createWorkspaceProject()
        let destination = Workspace.all.first { $0.projectId == third.id }!
        let window = TestWindow.new(id: 81001, parent: source.rootTilingContainer)
        let activeProject = activeWorkspaceProjectId(for: mainMonitor)
        applySidebarWorkspaceMove(sourceNode: window, sourceWindow: window, targetWorkspace: destination)
        XCTAssertTrue(window.nodeWorkspace === destination)
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), activeProject)
        let workspaces = await buildWorkspaceSidebarWorkspaceViewModels(currentFocus: focus, workspaceLabels: [:], availableMonitors: sortedMonitors)
        let grouped = workspaceSidebarVisibleWorkspacesByProject(workspaces: workspaces, selectedScopeId: workspaceSidebarDefaultScopeId, focusedMonitorScopeId: "")
        XCTAssertFalse(grouped[second.id, default: []].isEmpty)
        XCTAssertFalse(grouped[third.id, default: []].isEmpty)
        applySidebarWorkspaceMove(sourceNode: window, sourceWindow: window, targetWorkspace: source)
        XCTAssertTrue(window.nodeWorkspace === source)
    }

    func testTabGroupMovesTogetherAndCanCreateGroupInInactiveSpace() {
        setUpWorkspacesForTests()
        let source = focus.workspace
        let project = createWorkspaceProject()
        let destination = Workspace.all.first { $0.projectId == project.id }!
        let group = TilingContainer(parent: source.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, .v, .tabGroup, index: INDEX_BIND_LAST)
        let first = TestWindow.new(id: 81002, parent: group)
        let second = TestWindow.new(id: 81003, parent: group)
        applySidebarWorkspaceMove(sourceNode: group, sourceWindow: first, targetWorkspace: destination)
        XCTAssertTrue(first.parent === group)
        XCTAssertTrue(second.parent === group)
        XCTAssertTrue(first.nodeWorkspace === destination)
        XCTAssertTrue(second.nodeWorkspace === destination)
        XCTAssertTrue(focus.workspace === source)

        XCTAssertTrue(createWorkspaceFromSidebarDrag(sourceNode: group, sourceWindow: first, projectId: project.id, monitorScopeId: workspaceSidebarMonitorScopeId(for: mainMonitor)))
        XCTAssertEqual(first.nodeWorkspace?.projectId, project.id)
        XCTAssertTrue(first.parent === group)
        XCTAssertTrue(second.parent === group)
        XCTAssertTrue(focus.workspace === source)
    }

    func testSearchTraversesAllOrganizeColumnsInSavedOrder() async {
        setUpWorkspacesForTests()
        let project = createWorkspaceProject()
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.projects = buildWorkspaceSidebarProjectViewModels().reversed()
        snapshot.workspaces = await buildWorkspaceSidebarWorkspaceViewModels(currentFocus: focus, workspaceLabels: [:], availableMonitors: sortedMonitors)
        snapshot.browseMode = .organize
        let selections = WorkspaceSidebarView(snapshot: snapshot).currentSearchSelections()
        let firstWorkspace = snapshot.workspaces.first { $0.projectId == project.id }!
        XCTAssertEqual(selections.first, .workspace(firstWorkspace.name))
        XCTAssertEqual(selections.count, snapshot.workspaces.count)
    }

    func testProductionOrganizeViewUsesNativeHorizontalScrollView() async throws {
        setUpWorkspacesForTests()
        _ = createWorkspaceProject()
        _ = createWorkspaceProject()
        var snapshot = workspaceSidebarSnapshot(from: TrayMenuModel.shared)
        snapshot.projects = buildWorkspaceSidebarProjectViewModels()
        snapshot.workspaces = await buildWorkspaceSidebarWorkspaceViewModels(currentFocus: focus, workspaceLabels: [:], availableMonitors: sortedMonitors)
        snapshot.browseMode = .organize
        snapshot.configuration.expandedWidth = 280
        snapshot.visibleWidth = 500
        let host = NSHostingView(rootView: WorkspaceSidebarView(snapshot: snapshot))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 500, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let result = view as? T { return result }
            return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
        }
        let bridge = try XCTUnwrap(descendant(WorkspaceSidebarOrganizeScrollView.self, in: host))
        let scrollView = try XCTUnwrap(bridge.enclosingScrollView)
        XCTAssertGreaterThan(try XCTUnwrap(scrollView.documentView).bounds.width, scrollView.contentView.bounds.width)
        XCTAssertGreaterThan(scrollView.contentView.bounds.width, 0)
        bridge.stop()
    }
}
