@testable import AppBundle
import Foundation
import AppKit
import Common
import WorkspaceCore
import XCTest

@MainActor final class BrowserPagePresentationTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testProtocolFourAdoptsFirstPageWithoutManualGroupingAndReflectsNativeFocus() throws {
        let controller = BrowserWorkspaceController(foregroundProcessID: { -1 }), connection = UUID(), epoch = UUID()
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        controller.usesSurfaceTree = true
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [
            .init(surfaceID: page, hostID: "host", title: "Page", selected: true, focused: true),
        ]), epoch: epoch, connection: connection, protocolVersion: 4)
        _ = controller.organizedRows(native: [], in: focus.workspace.name)
        XCTAssertTrue(try XCTUnwrap(controller.capturePlacementSnapshot()).layoutWorkspaces.contains(focus.workspace.name))
        XCTAssertEqual(controller.focusCoordinator.target, page)
        XCTAssertEqual(controller.owner(of: page)?.supportsBrowserControls, true)
    }

    func testDelayedInventoryCannotTakeSelectionFromAnotherApp() {
        let controller = BrowserWorkspaceController(foregroundProcessID: { -2 }), connection = UUID()
        let native = TestWindow.new(id: 77, parent: focus.workspace.rootTilingContainer)
        controller.usesSurfaceTree = true
        controller.nativeSelectionChanged(native.surfaceID)
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [
            .init(surfaceID: page, hostID: "host", title: "Old focus", selected: true, focused: true),
        ]), epoch: UUID(), connection: connection, protocolVersion: 4)
        XCTAssertEqual(controller.focusCoordinator.target, native.surfaceID)
    }

    func testNewPageActionAllowsEngineToSelectItsNewWindow() {
        let controller = BrowserWorkspaceController(foregroundProcessID: { -1 }), connection = UUID(), epoch = UUID()
        let profile = UUID(), oldPage = SurfaceID.browserTab(profile: profile, tab: UUID()), newPage = SurfaceID.browserTab(profile: profile, tab: UUID())
        controller.usesSurfaceTree = true
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [
            .init(surfaceID: oldPage, hostID: "old", title: "Old", selected: true, focused: true),
        ]), epoch: epoch, connection: connection, protocolVersion: 4)
        controller.performToolbarAction(.newTab, for: oldPage)
        XCTAssertFalse(controller.holdsPendingBrowserFocus)
        controller.received(.init(revision: 2, full: false, tabs: [
            .init(surfaceID: oldPage, hostID: "old", title: "Old", selected: true, focused: false),
            .init(surfaceID: newPage, hostID: "new", title: "New", selected: true, focused: true),
        ]), epoch: epoch, connection: connection, protocolVersion: 4)
        XCTAssertEqual(controller.focusCoordinator.target, newPage)
    }

    func testStackRetainsIndependentHostsAndReservesNativeToolbar() throws {
        let profile = UUID(), a = SurfaceID.browserTab(profile: profile, tab: UUID()), b = SurfaceID.browserTab(profile: profile, tab: UUID())
        var tree = SurfaceTree(); tree.reconcile([a, b], in: "work"); tree.group(b, with: a)
        let placements = tree.placements(in: "work", frame: .init(x: -900, y: 25, width: 900, height: 700))
        let hosts = browserHostPlacements(placements, hasNativeToolbar: true)
        XCTAssertEqual(hosts.count, 2)
        XCTAssertTrue(hosts.allSatisfy(\.nativeControls))
        let legacy = browserHostPlacements(placements, hasNativeToolbar: false)
        XCTAssertEqual(legacy.count, 1)
        XCTAssertEqual(legacy.first?.surfaces.count, 2)
        XCTAssertEqual(legacy.first?.nativeControls, false)
        XCTAssertEqual(legacy.first?.y, 25)
        XCTAssertTrue(hosts.allSatisfy {
            $0.surfaces.count == 1 && $0.x == -892 && $0.y == 75 && $0.width == 884 && $0.height == 642
        })
        XCTAssertEqual(hosts.filter(\.visible).map(\.selected), [a])
        XCTAssertEqual(Set(hosts.map(\.containerID)).count, 1, "A shared stack is independent of native page hosts")
        tree.select(b)
        let next = browserHostPlacements(tree.placements(in: "work", frame: .init(x: -900, y: 25, width: 900, height: 700)), hasNativeToolbar: true)
        XCTAssertEqual(next.filter(\.visible).map(\.selected), [b])
        XCTAssertEqual(next.map(\.surfaces), hosts.map(\.surfaces))
    }

    func testPageChromeUnifiesHeaderAndBodyAcrossNegativeScreenCoordinates() throws {
        let geometry = try XCTUnwrap(BrowserPageChromeGeometry(frame: .init(x: -1440, y: -300, width: 720, height: 800)))
        XCTAssertEqual(geometry.pageFrame, .init(x: -1434, y: -294, width: 708, height: 788))
        XCTAssertEqual(geometry.headerFrame, .init(x: -1434, y: -294, width: 708, height: 44))
        XCTAssertEqual(geometry.bodyFrame, .init(x: -1432, y: -250, width: 704, height: 742))
        let outer = BrowserPageChromeGeometry.appKitRect(geometry.pageFrame, screenTop: 900)
        let header = BrowserPageChromeGeometry.appKitRect(geometry.headerFrame, screenTop: 900)
        let body = BrowserPageChromeGeometry.appKitRect(geometry.bodyFrame, screenTop: 900)
        XCTAssertEqual(outer, NSRect(x: -1434, y: 406, width: 708, height: 788))
        XCTAssertEqual(header.maxY, outer.maxY)
        XCTAssertEqual(header.minY, body.maxY, "Header and content must meet without a detached gap")
        XCTAssertEqual(body.minX - outer.minX, 2)
        XCTAssertEqual(outer.maxX - body.maxX, 2)
        XCTAssertEqual(body.minY - outer.minY, 2)
        XCTAssertTrue(outer.contains(header) && outer.contains(body))
    }

    func testNeighboringPageShellsHaveIndependentGutters() throws {
        let left = try XCTUnwrap(BrowserPageChromeGeometry(frame: .init(x: 0, y: 0, width: 640, height: 480)))
        let right = try XCTUnwrap(BrowserPageChromeGeometry(frame: .init(x: 640, y: 0, width: 640, height: 480)))
        let below = try XCTUnwrap(BrowserPageChromeGeometry(frame: .init(x: 0, y: 480, width: 640, height: 480)))
        XCTAssertEqual(right.pageFrame.x - left.pageFrame.x - left.pageFrame.width, 12)
        XCTAssertEqual(below.pageFrame.y - left.pageFrame.y - left.pageFrame.height, 12)
        XCTAssertEqual(left.headerFrame.width, left.pageFrame.width)
        XCTAssertEqual(right.headerFrame.width, right.pageFrame.width)
        XCTAssertNil(BrowserPageChromeGeometry(frame: .init(x: 0, y: 0, width: 16, height: 480)))
        XCTAssertNil(BrowserPageChromeGeometry(frame: .init(x: 0, y: 0, width: 640, height: 58)))
    }

    func testPageMinimumIncludesItsChromeWithoutShrinkingChromiumBelowItsMinimum() throws {
        let controller = BrowserWorkspaceController(foregroundProcessID: { -1 }), connection = UUID()
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        controller.usesSurfaceTree = true
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [
            .init(surfaceID: page, hostID: "host", title: "Page", selected: true,
                  hostMinimumSize: .init(width: 160, height: 120)),
        ]), epoch: UUID(), connection: connection, protocolVersion: 4)
        _ = controller.organizedRows(native: [], in: focus.workspace.name)
        let minimum = try XCTUnwrap(controller.minimumSizes(in: focus.workspace)[page])
        XCTAssertEqual(minimum, .init(width: 176, height: 178))
        let geometry = try XCTUnwrap(BrowserPageChromeGeometry(frame: .init(x: 0, y: 0, width: minimum.width, height: minimum.height)))
        XCTAssertEqual(geometry.bodyFrame.width, 160)
        XCTAssertEqual(geometry.bodyFrame.height, 120)
    }

    func testAddressNormalizationSupportsLocalDevelopmentAndRejectsActiveSchemes() {
        XCTAssertEqual(browserNavigationURL(" example.com/path "), "https://example.com/path")
        XCTAssertEqual(browserNavigationURL("localhost:5173/test"), "http://localhost:5173/test")
        XCTAssertEqual(browserNavigationURL("https://example.com"), "https://example.com")
        XCTAssertEqual(browserNavigationURL("chrome://extensions/"), "chrome://extensions/")
        XCTAssertEqual(browserNavigationURL("hello world"), "https://www.google.com/search?q=hello%20world")
        XCTAssertNil(browserNavigationURL("javascript:alert(1)"))
        XCTAssertNil(browserNavigationURL("data:text/html,hello"))
        XCTAssertNil(browserNavigationURL("  "))
    }
}
