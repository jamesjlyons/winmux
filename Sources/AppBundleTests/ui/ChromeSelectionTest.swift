@testable import AppBundle
import AppKit
import SwiftUI
import WorkspaceCore
import XCTest

@MainActor
final class ChromeSelectionTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testLayoutSelectionSurvivesFocusInAnotherPaneAndInventorySelectedFlags() throws {
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
        controller.usesSurfaceTree = true
        let profile = UUID(), workspace = focus.workspace.name
        let a = SurfaceID.browserTab(profile: profile, tab: UUID())
        let b = SurfaceID.browserTab(profile: profile, tab: UUID())
        let c = SurfaceID.browserTab(profile: profile, tab: UUID())
        var tree = SurfaceTree()
        tree.reconcile([a, b, c], in: workspace)
        XCTAssertTrue(tree.group(b, with: a))
        tree.select(a)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        defer { controller.disconnected(connection) }
        controller.received(.init(revision: 1, full: true, tabs: [
            .init(surfaceID: a, hostID: "a", title: "Documentation", selected: false, isLoading: true),
            .init(surfaceID: b, hostID: "b", title: "Other tab", selected: true),
            .init(surfaceID: c, hostID: "c", title: "Other pane", selected: true),
        ]), epoch: epoch, connection: connection)
        _ = controller.select(c)
        let rows = controller.organizedRows(native: [], in: workspace)
        let surfaces = rows.flatMap(\.surfaceItems)
        let selected = try XCTUnwrap(surfaces.first { $0.surfaceID == a })
        XCTAssertTrue(selected.isSelected)
        XCTAssertFalse(selected.isFocused)
        XCTAssertTrue(selected.isLoading)
        XCTAssertFalse(try XCTUnwrap(surfaces.first { $0.surfaceID == b }).isSelected,
                       "Chromium's host-selected flag must not override the stack selection")
        XCTAssertFalse(try XCTUnwrap(surfaces.first { $0.surfaceID == c }).isSelected,
                       "A standalone pane's focus must not become persistent stack selection")
        let model = WorkspaceSidebarWorkspaceViewModel(name: workspace, projectId: workspaceProjectDefaultId,
            displayName: "Work", sidebarLabel: "", isGeneratedName: false, monitorScopeId: "test", monitorName: nil,
            isFocused: true, isVisible: true, items: rows)
        let filtered = workspaceSidebarFilteredWorkspacesByProject([workspaceProjectDefaultId: [model]],
            projects: [], query: "Documentation")
        XCTAssertEqual(filtered[workspaceProjectDefaultId]?.first?.items.flatMap(\.surfaceItems), [selected])
        XCTAssertEqual(rows.flatMap(\.surfaceItems).count, 3, "Filtering must leave the full group metadata intact")
    }

    func testSplitContainersDoNotMarkEveryPaneSelected() {
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.nativeWindow(UUID())
        var tree = SurfaceTree(); tree.reconcile([a, b], in: "work")
        XCTAssertTrue(tree.group(b, with: a, layout: .horizontal))
        tree.select(a)
        XCTAssertTrue(workspaceSidebarSelectedSurfaces(in: tree).isEmpty)
    }

    func testSearchTargetAndGroupDoNotCompeteWithSelectedLeaf() {
        let selected = ChromeItemState(isSelected: true, isKeyboardTarget: true)
        XCTAssertTrue(selected.isRaised)
        XCTAssertFalse(selected.isHovered)
        XCTAssertFalse(selected.isFocused)
        XCTAssertFalse(ChromeItemState(isFocused: true, isGroup: true).isRaised)
        XCTAssertFalse(ChromeItemState(isHovered: true, isKeyboardTarget: true).isRaised)
    }

    func testOpenPinShowsLoadingAndClosedPinRetainsIdentityWithoutLoading() throws {
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
        controller.usesSurfaceTree = true
        let id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        defer { controller.disconnected(connection) }
        controller.received(.init(revision: 1, full: true, tabs: [
            .init(surfaceID: id, hostID: "pin", title: "Docs", selected: false,
                  url: "https://example.com", isLoading: true),
        ]), epoch: epoch, connection: connection, protocolVersion: 5)
        _ = controller.organizedRows(native: [], in: focus.workspace.name)
        XCTAssertTrue(controller.pinBrowserTab(id))
        let pin = try XCTUnwrap(controller.browserSidebarPins.first)
        let open = try XCTUnwrap(controller.pinTiles(in: pin.workspaceName).first)
        XCTAssertTrue(open.isOpen)
        XCTAssertTrue(open.isLoading)
        controller.received(.init(revision: 2, full: false, tabs: [], removed: [id]),
                            epoch: epoch, connection: connection, protocolVersion: 5)
        let closed = try XCTUnwrap(controller.pinTiles(in: pin.workspaceName).first)
        XCTAssertEqual(closed.id, open.id)
        XCTAssertFalse(closed.isOpen)
        XCTAssertFalse(closed.isLoading)
        XCTAssertFalse(closed.isSelected)
    }

    func testBrowserGlassDoesNotInterceptControlsAndAddressFitsHeader() {
        let background = BrowserChromeBackgroundView(headerOnly: false)
        background.frame = .init(x: 0, y: 0, width: 500, height: 400)
        XCTAssertNil(background.hitTest(.init(x: 20, y: 20)))
        XCTAssertFalse(background.isAccessibilityElement())
        let toolbar = BrowserToolbarView()
        toolbar.frame = .init(x: 0, y: 0, width: 500, height: BrowserToolbarController.height)
        toolbar.layoutSubtreeIfNeeded()
        let addressFrame = toolbar.address.superview!.frame
        XCTAssertEqual(addressFrame.height, 26)
        XCTAssertEqual(addressFrame.midY, toolbar.bounds.midY)
        XCTAssertTrue(toolbar.bounds.contains(addressFrame))
    }
}
