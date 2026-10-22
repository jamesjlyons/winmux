@testable import AppBundle
import AppKit
import Common
import SwiftUI
import WorkspaceCore
import XCTest

@MainActor
final class WorkspaceTopBarTest: XCTestCase {
    func testPlacementRoundTripsWithoutChangingSidePreferences() {
        let original = "[workspace-sidebar]\nvisibility = 'auto-hide'\nwidth = 280\ncollapsed-width = 36\n"
        for placement in WorkspaceNavigationPlacement.allCases {
            let text = updateSettingsScalarConfig(in: original, section: "workspace-sidebar", key: "placement", renderedValue: "'\(placement.rawValue)'")
            let result = parseConfig(text)
            XCTAssertTrue(result.errors.isEmpty, result.errors.description)
            XCTAssertEqual(result.config.workspaceSidebar.placement, placement)
            XCTAssertEqual(result.config.workspaceSidebar.visibility, .autoHide)
            XCTAssertEqual(result.config.workspaceSidebar.width, 280)
            XCTAssertEqual(result.config.workspaceSidebar.collapsedWidth, 36)
        }
        XCTAssertEqual(parseConfig(original).config.workspaceSidebar.placement, .side)
        XCTAssertFalse(parseConfig("[workspace-sidebar]\nplacement = 'bottom'").errors.isEmpty)
    }

    func testTopGeometryRespectsMenuBarNotchGapsAndOtherDisplayOrigins() {
        var settings = WorkspaceSidebarConfig()
        settings.placement = .top
        settings.topGap = 8
        settings.edgeGap = 12
        for origin in [CGPoint.zero, CGPoint(x: -1920, y: 200), CGPoint(x: 1512, y: -400)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 1512, height: 982))
            for menu: CGFloat in [0, 28, 38] {
                let visible = CGRect(x: screen.minX, y: screen.minY + 60, width: screen.width, height: screen.height - menu - 60)
                let bar = workspaceTopBarFrame(screenFrame: screen, visibleFrame: visible, configuration: settings)
                XCTAssertEqual(bar.maxY, screen.maxY - max(menu, 28) - 8)
                XCTAssertEqual(bar.height, 44)
                XCTAssertEqual(bar.minX, screen.minX + 12)
                XCTAssertEqual(bar.width, screen.width - 24)
                XCTAssertEqual(visible.maxY - bar.minY,
                    workspaceTopBarReservedHeight(settings, visibleHeight: visible.height, menuBarHeight: menu))
                XCTAssertEqual(workspaceSidebarReservedWidth(settings, screenWidth: screen.width), 0)
            }
        }
    }

    func testTopLayoutReclaimsSideInsetAndFullscreenRestoresExactPlacement() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.visibility = .expanded
        config.workspaceSidebar.width = 280
        config.gaps = .zero
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        XCTAssertEqual(mainMonitor.workspaceSidebarInset, 280)
        config.workspaceSidebar.placement = .top
        XCTAssertEqual(mainMonitor.workspaceSidebarInset, 0)
        XCTAssertGreaterThanOrEqual(mainMonitor.workspaceTopBarInset, 44)
        try await focus.workspace.layoutWorkspace()
        let rect = try await window.getAxRect()
        let top = try XCTUnwrap(rect)
        XCTAssertEqual(top.width, mainMonitor.visibleRect.width)
        XCTAssertEqual(top.topLeftY, mainMonitor.visibleRect.topLeftY + mainMonitor.workspaceTopBarInset)
        window.isFullscreen = true
        try await focus.workspace.layoutWorkspace()
        XCTAssertEqual(mainMonitor.workspaceTopBarInset, 0)
        window.isFullscreen = false
        try await focus.workspace.layoutWorkspace()
        let restored = try await window.getAxRect()
        XCTAssertEqual(restored, top)
        config.workspaceSidebar.placement = .side
        XCTAssertEqual(mainMonitor.workspaceSidebarInset, 280)
        XCTAssertEqual(mainMonitor.workspaceTopBarInset, 0)
        XCTAssertEqual(config.workspaceSidebar.visibility, .expanded)
    }

    func testTopInsetHonorsEnabledStateAndFullscreenOnOnlyOneDisplay() {
        setUpWorkspacesForTests()
        config.workspaceSidebar.placement = .top
        config.workspaceSidebar.enabled = true
        let main = mainMonitor
        let rect = Rect(topLeftX: main.rect.maxX, topLeftY: 0, width: 1920, height: 1080)
        let secondary = TestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Secondary", rect: rect, visibleRect: rect, isMain: false)
        setMonitorsForTests([main, secondary])
        let workspace = Workspace.get(byName: "second")
        XCTAssertTrue(secondary.setActiveWorkspace(workspace))
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer).isFullscreen = true
        XCTAssertGreaterThan(main.workspaceTopBarInset, 0)
        XCTAssertEqual(secondary.workspaceTopBarInset, 0)
        config.workspaceSidebar.enabled = false
        XCTAssertEqual(main.workspaceTopBarInset, 0)
    }

    func testSearchFieldRoutesListCommandsButLeavesTextEditingNative() {
        var moves: [Int] = [], selected = false, cancelled = false
        let field = WorkspaceTopSearchField(text: .constant("query"), move: { moves.append($0) },
            select: { selected = true }, cancel: { cancelled = true })
        let coordinator = field.makeCoordinator()
        let control = NSSearchField(), editor = NSTextView()
        for selector in [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)),
                         #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
            XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: selector))
        }
        XCTAssertEqual(moves, [1, -1])
        XCTAssertTrue(selected)
        XCTAssertTrue(cancelled)
        XCTAssertFalse(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        XCTAssertFalse(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        editor.setMarkedText("composing", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    }

    func testReorderUsesHorizontalCentersAndFrozenPositions() {
        let frames = ["a": CGRect(x: 0, y: 0, width: 100, height: 32),
                      "b": CGRect(x: 104, y: 0, width: 180, height: 32),
                      "c": CGRect(x: 288, y: 0, width: 120, height: 32)]
        XCTAssertNil(workspaceTopTabReorderTarget(source: "a", locationX: 190, frames: frames))
        XCTAssertEqual(workspaceTopTabReorderTarget(source: "a", locationX: 200, frames: frames), .init(name: "b", placement: .after))
        XCTAssertEqual(workspaceTopTabReorderTarget(source: "a", locationX: 360, frames: frames), .init(name: "c", placement: .after))
        XCTAssertEqual(workspaceTopTabReorderTarget(source: "c", locationX: 40, frames: frames), .init(name: "a", placement: .before))
        XCTAssertNil(workspaceTopTabReorderTarget(source: "missing", locationX: 30, frames: frames))
        XCTAssertNil(workspaceTopTabReorderTarget(source: "a", locationX: .nan, frames: frames))
    }

    func testViewsSearchKeepsArrangementCountAndSpaceAndDisplayScope() {
        var snapshot = WorkspaceSidebarSnapshot.empty
        let primary = workspaceProjectDefaultId, other = WorkspaceProjectId(rawValue: "other")
        snapshot.activeProjectId = primary
        snapshot.projects = [.init(id: primary, displayName: "Work", colorHex: nil), .init(id: other, displayName: "Personal", colorHex: nil)]
        func item(_ title: String) -> WorkspaceSidebarItemViewModel {
            .init(kind: .surface(.init(surfaceID: .nativeWindow(UUID()), title: title, appName: "Safari", isFocused: false)))
        }
        func view(_ name: String, project: WorkspaceProjectId, monitor: String, items: [WorkspaceSidebarItemViewModel]) -> WorkspaceSidebarWorkspaceViewModel {
            .init(name: name, projectId: project, displayName: name, sidebarLabel: "", isGeneratedName: false,
                  monitorScopeId: monitor, monitorName: nil, isFocused: false, isVisible: false, items: items)
        }
        snapshot.workspaces = [view("Website", project: primary, monitor: "one", items: [item("Design notes"), item("Terminal")]),
            view("Mail", project: other, monitor: "two", items: [item("Inbox")])]
        XCTAssertEqual(workspaceTopBarWorkspaces(snapshot).map(\.name), ["Website"])
        XCTAssertEqual(workspaceTopBarWorkspaces(snapshot, allSpaces: true).map(\.name), ["Website", "Mail"])
        let filtered = workspaceTopBarWorkspaces(snapshot, query: "terminal")
        XCTAssertEqual(filtered.first?.viewSurfaceCount, 2)
        XCTAssertEqual(filtered.first?.viewSurfaces.map(\.title), ["Terminal"])
        snapshot.selectedMonitorScopeId = "two"
        XCTAssertTrue(workspaceTopBarWorkspaces(snapshot).isEmpty)
        XCTAssertEqual(workspaceTopBarWorkspaces(snapshot, allSpaces: true).map(\.name), ["Mail"])
    }

    func testPinsStaySearchableOutsideDisplayFilterAndDoNotBecomeViewTabs() {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.projects = [.init(id: snapshot.activeProjectId, displayName: "Work", colorHex: nil)]
        let pin = WorkspaceSidebarPinViewModel(id: UUID(), workspaceName: "pins", title: "Documentation",
            bundleIdentifier: nil, bundlePath: nil, iconPNGBase64: nil, surfaceID: nil, isFocused: false,
            isOpen: false, isLoading: false, isUnavailable: false, isBrowser: true)
        snapshot.workspaces = [.init(name: "pins", projectId: snapshot.activeProjectId, displayName: "Pinned", sidebarLabel: "",
            isGeneratedName: false, monitorScopeId: "other", monitorName: nil, isFocused: false, isVisible: false,
            items: [], isPinnedGroup: true, pins: [pin])]
        snapshot.selectedMonitorScopeId = "main"
        XCTAssertEqual(workspaceTopBarPins(snapshot, query: "doc").map(\.id), [pin.id])
        XCTAssertTrue(workspaceTopBarPins(snapshot, query: "missing").isEmpty)
        XCTAssertTrue(workspaceTopBarWorkspaces(snapshot).isEmpty)
    }
}
