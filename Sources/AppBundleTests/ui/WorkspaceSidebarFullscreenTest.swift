@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class WorkspaceSidebarFullscreenTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.collapsedWidth = 28
        config.gaps = .zero
    }

    func testFullscreenReclaimsSidebarInsetAndRestoresItOnExit() async throws {
        let workspace = focus.workspace
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        XCTAssertEqual(mainMonitor.workspaceSidebarInset, 28)

        window.isFullscreen = true
        try await workspace.layoutWorkspace()

        XCTAssertTrue(shouldSuppressWorkspaceSidebarForFullscreenContent(on: mainMonitor))
        XCTAssertEqual(mainMonitor.workspaceSidebarInset, 0)
        let fullscreenRect = try await window.getAxRect()
        XCTAssertEqual(fullscreenRect, mainMonitor.visibleRect)

        window.isFullscreen = false
        try await workspace.layoutWorkspace()

        XCTAssertFalse(shouldSuppressWorkspaceSidebarForFullscreenContent(on: mainMonitor))
        XCTAssertEqual(mainMonitor.workspaceSidebarInset, 28)
        let observedRestoredRect = try await window.getAxRect()
        let restoredRect = try XCTUnwrap(observedRestoredRect)
        XCTAssertEqual(restoredRect.topLeftX, mainMonitor.visibleRect.topLeftX + 28)
        XCTAssertEqual(restoredRect.width, mainMonitor.visibleRect.width - 28)
    }

    func testAlwaysExpandedSidebarKeepsConfiguredGapsWhileFullscreen() {
        config.workspaceSidebar.alwaysExpanded = true
        config.workspaceSidebar.width = 280
        config.gaps = Gaps(inner: .zero, outer: Gaps.Outer(left: 8, bottom: 0, top: 0, right: 10))
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        XCTAssertEqual(mainMonitor.workspaceSidebarInset, 280)

        window.isFullscreen = true
        XCTAssertEqual(mainMonitor.workspaceSidebarInset, 0)
        XCTAssertEqual(mainMonitor.visibleRectPaddedByOuterGaps.topLeftX, mainMonitor.visibleRect.topLeftX + 8)
        XCTAssertEqual(mainMonitor.visibleRectPaddedByOuterGaps.width, mainMonitor.visibleRect.width - 18)

        window.isFullscreen = false
        XCTAssertEqual(mainMonitor.workspaceSidebarInset, 280)
    }

    func testFullscreenTabKeepsSidebarHiddenWhenSwitchingTabs() async throws {
        let workspace = focus.workspace
        let group = TilingContainer(parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, .h, .tabGroup, index: INDEX_BIND_LAST)
        let first = TestWindow.new(id: 1, parent: group)
        let second = TestWindow.new(id: 2, parent: group)
        first.isFullscreen = true
        second.markAsMostRecentChild()

        try await workspace.layoutWorkspace()

        XCTAssertTrue(shouldSuppressWorkspaceSidebarForFullscreenContent(on: mainMonitor))
        let fullscreenRect = try await second.getAxRect()
        XCTAssertEqual(fullscreenRect, mainMonitor.visibleRect)

        first.isFullscreen = false
        XCTAssertFalse(shouldSuppressWorkspaceSidebarForFullscreenContent(on: mainMonitor))
        XCTAssertEqual(mainMonitor.workspaceSidebarInset, 28)
    }

    func testInactiveFullscreenWindowDoesNotHideSidebar() {
        let root = focus.workspace.rootTilingContainer
        let fullscreen = TestWindow.new(id: 1, parent: root)
        let active = TestWindow.new(id: 2, parent: root)
        fullscreen.isFullscreen = true
        active.markAsMostRecentChild()

        XCTAssertFalse(shouldSuppressWorkspaceSidebarForFullscreenContent(on: mainMonitor))
        XCTAssertEqual(mainMonitor.workspaceSidebarInset, 28)
    }

    func testSwitchingAwayFromFullscreenWorkspaceRestoresSidebar() {
        let fullscreenWorkspace = focus.workspace
        TestWindow.new(id: 1, parent: fullscreenWorkspace.rootTilingContainer).isFullscreen = true
        XCTAssertTrue(shouldSuppressWorkspaceSidebarForFullscreenContent(on: mainMonitor))

        XCTAssertTrue(mainMonitor.setActiveWorkspace(Workspace.get(byName: "normal")))
        XCTAssertFalse(shouldSuppressWorkspaceSidebarForFullscreenContent(on: mainMonitor))
        XCTAssertEqual(mainMonitor.workspaceSidebarInset, 28)

        XCTAssertTrue(mainMonitor.setActiveWorkspace(fullscreenWorkspace))
        XCTAssertTrue(shouldSuppressWorkspaceSidebarForFullscreenContent(on: mainMonitor))
    }

    func testFullscreenOnlyHidesSidebarOnItsMonitor() {
        let main = mainMonitor
        let secondaryRect = Rect(topLeftX: main.rect.maxX, topLeftY: 0, width: 1920, height: 1080)
        let secondary = TestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Secondary", rect: secondaryRect, visibleRect: secondaryRect, isMain: false)
        setMonitorsForTests([main, secondary])
        let secondaryWorkspace = Workspace.get(byName: "secondary")
        XCTAssertTrue(secondary.setActiveWorkspace(secondaryWorkspace))
        TestWindow.new(id: 1, parent: secondaryWorkspace.rootTilingContainer).isFullscreen = true

        XCTAssertFalse(shouldSuppressWorkspaceSidebarForFullscreenContent(on: main))
        XCTAssertEqual(main.workspaceSidebarInset, 28)
        XCTAssertTrue(shouldSuppressWorkspaceSidebarForFullscreenContent(on: secondary))
        XCTAssertEqual(secondary.workspaceSidebarInset, 0)
    }

    func testNativeFullscreenHidesSidebarAndRestoresItOnExit() async {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        window.nativeIsMacosFullscreen = true
        await updateNativeFullscreenChromeSuppression(nativeFocused: window)
        XCTAssertTrue(shouldSuppressWorkspaceSidebarForFullscreenContent(on: mainMonitor))
        XCTAssertEqual(mainMonitor.workspaceSidebarInset, 0)

        window.nativeIsMacosFullscreen = false
        await updateNativeFullscreenChromeSuppression(nativeFocused: window)
        XCTAssertFalse(shouldSuppressWorkspaceSidebarForFullscreenContent(on: mainMonitor))
        XCTAssertEqual(mainMonitor.workspaceSidebarInset, 28)
    }
}
