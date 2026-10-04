import Foundation
import XCTest
@testable import WorkspaceCore

final class SpacePinnedGroupTests: XCTestCase {
    func testMixedPinsOrderAndLastRegularGroupRoundTrip() throws {
        let browser = BrowserSidebarPin(profileID: UUID(), workspaceName: "Pins", title: "Mail", url: "https://example.com", iconPNGBase64: "thumbnail")
        let app = NativeAppSidebarPin(workspaceName: "Pins", bundleIdentifier: "com.apple.TextEdit", bundlePath: "/System/Applications/TextEdit.app", title: "TextEdit")
        let group = SpacePinnedGroup(spaceID: "Work", workspaceName: "Pins", lastRegularWorkspaceName: "Group 2", pinOrder: [app.id, browser.id])
        let snapshot = SurfaceWorkspaceSnapshot(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: [], browserPins: [browser], appPins: [app], pinnedGroups: [group])
        let saved = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: saved).validated(), snapshot)
    }

    func testLegacySnapshotsHaveNoAppPinsOrPinnedGroupMetadata() throws {
        let snapshot = SurfaceWorkspaceSnapshot(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: [])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        for key in ["appPins", "pinnedGroups"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(decoded.appPins.isEmpty); XCTAssertTrue(decoded.pinnedGroups.isEmpty)
        XCTAssertNoThrow(try decoded.validated())
    }

    func testRejectsDuplicateGroupsAppsCrossGroupBindingsAndForeignOrder() {
        let live = SurfaceID.nativeWindow(UUID())
        let app = NativeAppSidebarPin(workspaceName: "Pins", bundleIdentifier: "com.apple.TextEdit", bundlePath: "/System/Applications/TextEdit.app", title: "TextEdit", surfaceID: live)
        let group = SpacePinnedGroup(spaceID: "Work", workspaceName: "Pins", pinOrder: [app.id])
        func snapshot(_ apps: [NativeAppSidebarPin], _ groups: [SpacePinnedGroup], tree: SurfaceTree = .init()) -> SurfaceWorkspaceSnapshot {
            .init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: [], appPins: apps, pinnedGroups: groups)
        }
        XCTAssertThrowsError(try snapshot([app], [group, group]).validated())
        let duplicate = NativeAppSidebarPin(workspaceName: "Pins", bundleIdentifier: app.bundleIdentifier, bundlePath: app.bundlePath, title: app.title)
        XCTAssertThrowsError(try snapshot([app, duplicate], [group]).validated())
        var foreign = group; foreign.pinOrder.append(UUID())
        XCTAssertThrowsError(try snapshot([app], [foreign]).validated())
        XCTAssertThrowsError(try snapshot([app], []).validated())
        var tree = SurfaceTree(); tree.reconcile([live], in: "Regular")
        XCTAssertThrowsError(try snapshot([app], [group], tree: tree).validated())
    }
}
