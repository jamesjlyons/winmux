@testable import AppBundle
import AppKit
import SwiftUI
import WorkspaceCore
import XCTest

@MainActor
final class WorkspaceSidebarFloatingWindowTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }
    override func tearDown() async throws { setUpWorkspacesForTests() }

    func testFloatingWindowsKeepTheirSpaceAndStayOutsideTiledOrganization() async throws {
        let controller = BrowserWorkspaceController.shared
        controller.usesSurfaceTree = true
        let workspace = focus.workspace
        let tiled = TestWindow.new(id: 6201, parent: workspace.rootTilingContainer)
        let floating = TestWindow.new(id: 6202, parent: workspace)
        controller.reconcileSharedOrganization()
        let before = controller.surfaceTree

        let models = await buildWorkspaceSidebarWorkspaceViewModels(currentFocus: focus,
            workspaceLabels: [:], availableMonitors: [mainMonitor])
        let model = try XCTUnwrap(models.first { $0.name == workspace.name })
        XCTAssertEqual(model.projectId, workspace.projectId)
        XCTAssertEqual(model.items.flatMap(\.surfaceIDs), [tiled.surfaceID, floating.surfaceID])
        XCTAssertEqual(model.floatingItems.flatMap(\.surfaceIDs), [floating.surfaceID])
        XCTAssertTrue(try XCTUnwrap(model.floatingItems.first?.surfaceItems.first).isFloating)
        XCTAssertEqual(controller.select(floating.surfaceID), .issued)
        XCTAssertTrue(floating.isFloating)
        XCTAssertEqual(controller.workspaceName(for: floating.surfaceID), workspace.name)
        XCTAssertEqual(controller.surfaceTree, before, "Showing and selecting a float must not tile it")
    }

    func testPinnedDesktopWithoutPinsStillShowsItsFloatingWindow() async throws {
        let workspace = focus.workspace
        workspace.isPinnedGroup = true
        let floating = TestWindow.new(id: 6210, parent: workspace)
        XCTAssertTrue(isUserFacingWorkspace(workspace))
        XCTAssertTrue(userFacingWorkspaces([workspace]).contains { $0 === workspace })
        let models = await buildWorkspaceSidebarWorkspaceViewModels(currentFocus: focus,
            workspaceLabels: [:], availableMonitors: [mainMonitor])
        let model = try XCTUnwrap(models.first { $0.name == workspace.name })
        XCTAssertTrue(model.pins.isEmpty)
        XCTAssertTrue(model.showsWindowSection)
        XCTAssertEqual(model.floatingItems.flatMap(\.surfaceIDs), [floating.surfaceID])
    }

    func testFloatingTransitionsUpdateStaleRowsWithoutDuplicatesOrMovingOwners() async throws {
        let controller = BrowserWorkspaceController.shared
        controller.usesSurfaceTree = true
        let workspace = focus.workspace
        let window = TestWindow.new(id: 6220, parent: workspace.rootTilingContainer)
        controller.reconcileSharedOrganization()
        let tiledRows = await buildWorkspaceSidebarNativeItems(for: workspace, currentFocus: focus)
        window.bindAsFloatingWindow(to: workspace)
        controller.nativeTilingStateChanged(window)
        let floatingRows = controller.organizedRows(native: tiledRows, in: workspace.name)
        XCTAssertEqual(floatingRows.flatMap(\.surfaceIDs), [window.surfaceID])
        XCTAssertTrue(try XCTUnwrap(floatingRows.first?.surfaceItems.first).isFloating)

        window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        controller.nativeTilingStateChanged(window)
        let restored = controller.organizedRows(native: floatingRows, in: workspace.name)
        XCTAssertEqual(restored.flatMap(\.surfaceIDs), [window.surfaceID])
        XCTAssertFalse(try XCTUnwrap(restored.first?.surfaceItems.first).isFloating)

        let destination = Workspace.get(byName: "other-space-view")
        window.bindAsFloatingWindow(to: destination)
        controller.nativeTilingStateChanged(window)
        XCTAssertTrue(controller.organizedRows(native: floatingRows, in: workspace.name).isEmpty)
        let destinationRows = await buildWorkspaceSidebarNativeItems(for: destination, currentFocus: focus)
        XCTAssertEqual(controller.organizedRows(native: destinationRows, in: destination.name).flatMap(\.surfaceIDs), [window.surfaceID])
        window.unbindFromParent()
        XCTAssertTrue(controller.organizedRows(native: destinationRows, in: destination.name).isEmpty)
    }

    func testPinnedFloatingWindowsCanBeSearchedAndKeyboardSelected() throws {
        let snapshot = fixture()
        let pinned = try XCTUnwrap(snapshot.workspaces.first)
        let floatID = try XCTUnwrap(pinned.floatingItems.first?.surfaceIDs.first)
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [pinned]),
            [.pinnedBrowserTab(pinned.pins[0].id)] + pinned.floatingItems.flatMap(\.surfaceIDs).map { .surface($0) })
        let result = workspaceSidebarFilteredWorkspacesByProject(
            [workspaceProjectDefaultId: snapshot.workspaces], projects: snapshot.projects, query: "Inspector")
        let filtered = try XCTUnwrap(result[workspaceProjectDefaultId]?.first)
        XCTAssertEqual(filtered.name, pinned.name)
        XCTAssertTrue(filtered.pins.isEmpty)
        XCTAssertTrue(filtered.showsWindowSection)
        XCTAssertEqual(filtered.floatingItems.flatMap(\.surfaceIDs), [floatID])
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [filtered]), [.surface(floatID)])
    }

    func testSingleFloatingViewActivatesItsWindowDirectly() {
        let workspace = fixture().workspaces[1]
        var sent: [WorkspaceSidebarAction] = []
        let section = WorkspaceSidebarWorkspaceSection(workspace: workspace, targetMonitorScopeId: "display",
            dragPreview: nil, expansionProgress: 1, layout: .empty, emitsDropTarget: false,
            isFromOtherDisplay: false, isInUseOnOtherDisplay: false, isOnFocusedMonitor: true,
            allowsWorkspaceActivation: true, isPinnedActiveWorkspace: false, isActiveOnTargetMonitor: true,
            projectContextLabel: nil, projectContextColor: nil,
            renamingWorkspaceName: .constant(nil), renamingWorkspaceText: .constant(""),
            onBeginRenameWorkspace: {}, onCommitRenameWorkspace: {}, onCancelRenameWorkspace: {},
            selectedSearchTarget: nil, isSearchFiltering: false, activeInUseOverrideWorkspaceName: .constant(nil),
            actions: .init(send: { sent.append($0) }))
        section.handleSectionClick()
        XCTAssertEqual(sent, [.selectSurface(workspace.viewSurfaces[0].surfaceID)])
    }

    func testPinFloatsOccupyVisibleRowsInExpandedAndCompactSidebar() async throws {
        let snapshot = fixture()
        var withoutFloats = snapshot
        withoutFloats.workspaces[0].items.removeAll { $0.surfaceItems.contains(where: \.isFloating) }
        for width: CGFloat in [40, 240] {
            let baseline = try await followingViewFrame(withoutFloats, width: width)
            let actual = try await followingViewFrame(snapshot, width: width)
            XCTAssertGreaterThanOrEqual(abs(actual.minY - baseline.minY), workspaceSidebarWorkspaceRowHeight * 2,
                "Both pin-owned floating windows must occupy rows, width \(width)")
        }
        if let directory = ProcessInfo.processInfo.environment["WINMUX_FLOATING_PROOF_DIRECTORY"] {
            let output = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for light in [true, false] {
                let scene = HStack(alignment: .top, spacing: 24) {
                    WorkspaceSidebarView(snapshot: snapshot, actions: .init()).frame(width: 240, height: 430)
                    WorkspaceSidebarView(snapshot: sized(snapshot, width: 40), actions: .init()).frame(width: 40, height: 430)
                }.padding(16).background(Color(nsColor: .windowBackgroundColor))
                try renderMarketingView(scene, to: output.appendingPathComponent(light ? "light.png" : "dark.png"),
                    size: .init(width: 336, height: 462), colorScheme: light ? .light : .dark)
            }
        }
    }

    private func followingViewFrame(_ snapshot: WorkspaceSidebarSnapshot, width: CGFloat) async throws -> CGRect {
        var frame: CGRect?
        let view = WorkspaceSidebarView(snapshot: sized(snapshot, width: width), actions: .init(setDropTargets: { targets in
            frame = targets.first { $0.kind == .workspace("scratchpad") }?.frame
        })).transaction { $0.disablesAnimations = true }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        return try XCTUnwrap(frame)
    }

    private func sized(_ snapshot: WorkspaceSidebarSnapshot, width: CGFloat) -> WorkspaceSidebarSnapshot {
        var result = snapshot
        result.visibleWidth = width
        return result
    }

    private func fixture() -> WorkspaceSidebarSnapshot {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.visibleWidth = 240
        snapshot.configuration.collapsedWidth = 40
        snapshot.configuration.expandedWidth = 240
        snapshot.configuration.showsBrowserControls = true
        snapshot.configuration.chromeStyle = .solid
        snapshot.targetMonitorScopeId = "display"
        snapshot.focusedMonitorScopeId = "display"
        snapshot.projects = [.init(id: workspaceProjectDefaultId, displayName: "Work", colorHex: nil)]
        func item(_ title: String, floating: Bool) -> WorkspaceSidebarItemViewModel {
            .init(kind: .window(.init(windowId: 1, workspaceName: "pins", appName: title,
                appBundleId: "com.apple.Notes", appBundlePath: nil, title: title,
                isFocused: false, surfaceID: .nativeWindow(UUID()), isFloating: floating)))
        }
        func workspace(_ name: String, items: [WorkspaceSidebarItemViewModel]) -> WorkspaceSidebarWorkspaceViewModel {
            .init(name: name, projectId: workspaceProjectDefaultId, displayName: name.capitalized,
                sidebarLabel: "", isGeneratedName: true, monitorScopeId: "display", monitorName: nil,
                isFocused: false, isVisible: false, items: items)
        }
        var pins = workspace("pins", items: [item("Pinned editor", floating: false),
            item("Inspector", floating: true), item("Quick note", floating: true)])
        pins.isPinnedGroup = true
        pins.pins = [.init(id: UUID(), workspaceName: "pins", title: "Notes", bundleIdentifier: "com.apple.Notes",
            bundlePath: nil, iconPNGBase64: nil, surfaceID: nil, isFocused: false,
            isOpen: true, isLoading: false, isUnavailable: false, isBrowser: false)]
        snapshot.workspaces = [pins, workspace("scratchpad", items: [item("Scratchpad", floating: true)]),
            workspace("reference", items: [item("Reference", floating: false)])]
        return snapshot
    }
}
