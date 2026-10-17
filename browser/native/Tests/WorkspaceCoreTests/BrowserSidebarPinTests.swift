import Foundation
import XCTest
@testable import WorkspaceCore

final class BrowserSidebarPinTests: XCTestCase {
    func testSnapshotRoundTripPreservesClosedPinsWithoutLayoutMembership() throws {
        let profile = UUID(), live = SurfaceID.browserTab(profile: profile, tab: UUID())
        var tree = SurfaceTree(); tree.reconcile([live], in: "Work")
        let pins = [BrowserSidebarPin(profileID: profile, workspaceName: "Work", title: "Docs", url: "https://example.com/docs", surfaceID: live),
                    BrowserSidebarPin(profileID: profile, workspaceName: "Saved", title: "Mail", url: "https://example.com/mail")]
        let snapshot = SurfaceWorkspaceSnapshot(tree: tree, layoutWorkspaces: ["Work"], selected: live,
                                                closedBrowserTabs: [], browserPins: pins)
        let decoded = try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(try decoded.validated(), snapshot)
        XCTAssertNil(decoded.tree.roots["Saved"], "A closed pin does not reserve a layout pane")
        XCTAssertNil(decoded.browserPins.last?.surfaceID)
        XCTAssertEqual(decoded.browserPins.last?.profileID, profile)
    }

    func testExistingReferenceOnlySnapshotsDecodeWithoutPins() throws {
        let snapshot = SurfaceWorkspaceSnapshot(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: [])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        json.removeValue(forKey: "browserPins")
        let decoded = try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(decoded.browserPins.isEmpty)
        XCTAssertTrue(decoded.restoringBrowserPinBindings.isEmpty)
        XCTAssertNoThrow(try decoded.validated())
    }

    func testSnapshotRetainsPendingPinIdentityWithoutReservingALivePane() throws {
        let profile = UUID(), missing = SurfaceID.browserTab(profile: profile, tab: UUID())
        let pin = BrowserSidebarPin(profileID: profile, workspaceName: "Pins", title: "Docs", url: "https://example.com")
        let snapshot = SurfaceWorkspaceSnapshot(tree: .init(), layoutWorkspaces: [], selected: nil,
            closedBrowserTabs: [missing], browserPins: [pin], restoringBrowserPinBindings: [missing: pin.id])
        let decoded = try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot)).validated()
        XCTAssertEqual(decoded, snapshot)
        XCTAssertNil(decoded.browserPins.first?.surfaceID)
        XCTAssertTrue(decoded.tree.roots.isEmpty)
    }

    func testSnapshotRejectsConflictingPinRecoveryIdentities() throws {
        let profile = UUID(), missing = SurfaceID.browserTab(profile: profile, tab: UUID())
        let pin = BrowserSidebarPin(profileID: profile, workspaceName: "Pins", title: "Docs", url: "https://example.com")
        let base = SurfaceWorkspaceSnapshot(tree: .init(), layoutWorkspaces: [], selected: nil,
            closedBrowserTabs: [], browserPins: [pin])
        for invalid: [SurfaceID: UUID] in [
            [.nativeWindow(UUID()): pin.id],
            [.browserTab(profile: UUID(), tab: UUID()): pin.id],
            [missing: UUID()],
            [missing: pin.id, .browserTab(profile: profile, tab: UUID()): pin.id],
        ] {
            var snapshot = base
            snapshot.restoringBrowserPinBindings = invalid
            XCTAssertThrowsError(try snapshot.validated())
        }
        var alreadyPlaced = base
        alreadyPlaced.restoringBrowserPinBindings = [missing: pin.id]
        alreadyPlaced.tree.reconcile([missing], in: "Regular")
        XCTAssertThrowsError(try alreadyPlaced.validated())
        var open = pin
        open.surfaceID = .browserTab(profile: profile, tab: UUID())
        let snapshot = SurfaceWorkspaceSnapshot(tree: .init(), layoutWorkspaces: [], selected: nil,
            closedBrowserTabs: [], browserPins: [open], restoringBrowserPinBindings: [missing: pin.id])
        XCTAssertThrowsError(try snapshot.validated())
    }

    func testRejectsDuplicatePinIdentityAndConflictingLiveBindings() throws {
        let profile = UUID(), live = SurfaceID.browserTab(profile: profile, tab: UUID())
        let pin = BrowserSidebarPin(profileID: profile, workspaceName: "Work", title: "Docs", url: "https://example.com", surfaceID: live)
        func snapshot(_ pins: [BrowserSidebarPin], closed: Set<SurfaceID> = []) -> SurfaceWorkspaceSnapshot {
            .init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: closed, browserPins: pins)
        }
        XCTAssertThrowsError(try snapshot([pin, pin]).validated())
        let duplicateLive = BrowserSidebarPin(profileID: profile, workspaceName: "Work", title: "Other", url: "https://example.com/other", surfaceID: live)
        XCTAssertThrowsError(try snapshot([pin, duplicateLive]).validated())
        XCTAssertThrowsError(try snapshot([pin], closed: [live]).validated())
        let wrongProfile = BrowserSidebarPin(profileID: UUID(), workspaceName: "Work", title: "Docs", url: "https://example.com", surfaceID: live)
        XCTAssertThrowsError(try snapshot([wrongProfile]).validated())
        let native = BrowserSidebarPin(profileID: profile, workspaceName: "Work", title: "Native", url: "https://example.com", surfaceID: .nativeWindow(UUID()))
        XCTAssertThrowsError(try snapshot([native]).validated())
        let emptyURL = BrowserSidebarPin(profileID: profile, workspaceName: "Work", title: "Empty", url: "")
        XCTAssertThrowsError(try snapshot([emptyURL]).validated())
    }
}
