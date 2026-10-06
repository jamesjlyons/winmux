import Foundation
import XCTest
@testable import WorkspaceCore

final class PinnedDesktopTests: XCTestCase {
    func testClosedMemberRestoresItsOriginalSlotWeightAndActiveStack() throws {
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let replacement = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let memberA = UUID(), memberB = UUID(), group = UUID()
        let template: [PinnedLayoutNode] = [.group(group, .stack, [.member(memberA, 2), .member(memberB, 3)], memberB, 4)]
        var tree = SurfaceTree(); tree.reconcile([a, b], in: "Pin")
        tree.restorePinnedLayout(template, bindings: [memberA: a], in: "Pin")
        XCTAssertEqual(tree.roots["Pin"]?.flatMap(\.surfaces), [a, b])
        tree.remove(b)
        tree.reconcile([a, replacement], in: "Pin")
        tree.restorePinnedLayout(template, bindings: [memberA: a, memberB: replacement], in: "Pin")
        XCTAssertEqual(tree.roots["Pin"], [.group(group, [.surface(a), .surface(replacement)])])
        XCTAssertEqual(tree.activeSurfaces[group], replacement)
        XCTAssertEqual(tree.weights[SurfaceTreeNode.surface(replacement).weightKey], 3)
        XCTAssertEqual(tree.weights[SurfaceTreeNode.group(group, []).weightKey], 4)
    }

    func testTemplateRejectsDuplicateMembersGroupsAndInvalidWeights() {
        let a = UUID(), group = UUID()
        var pin = PinnedDesktop(spaceID: "Work", workspaceName: "Pin", title: "Group", kind: .group, memberIDs: [a], layout: [.member(a, 1)])
        XCTAssertTrue(pin.isValid)
        pin.layout = [.member(a, 0)]; XCTAssertFalse(pin.isValid)
        pin.layout = [.member(a, 0.5)]; XCTAssertFalse(pin.isValid)
        pin.layout = [.member(a, 30001)]; XCTAssertFalse(pin.isValid)
        pin.layout = [.member(a, .infinity)]; XCTAssertFalse(pin.isValid)
        pin.layout = [.member(a, 1), .member(a, 1)]; XCTAssertFalse(pin.isValid)
        pin.layout = [.group(group, .stack, [.group(group, .stack, [.member(a, 1)], nil, 1)], nil, 1)]
        XCTAssertFalse(pin.isValid)
    }

    func testShelfMustCoverEveryDesktopAndRoundTripsClosedMembers() throws {
        let member = BrowserSidebarPin(profileID: UUID(), workspaceName: "Pin", title: "Docs", url: "https://example.com")
        let pin = PinnedDesktop(spaceID: "Work", workspaceName: "Pin", title: "Docs", kind: .tab, memberIDs: [member.id], layout: [.member(member.id, 1)])
        var snapshot = SurfaceWorkspaceSnapshot(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: [], browserPins: [member], pinnedDesktops: [pin])
        XCTAssertThrowsError(try snapshot.validated())
        snapshot.pinShelves = [.init(spaceID: "Work", desktopOrder: [pin.id])]
        XCTAssertEqual(try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot)).validated(), snapshot)
    }

    func testBootstrapConsentIsOffUntilExplicitlySavedAndMalformedFailsClosed() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: profile) }
        XCTAssertEqual(BrowserServiceConsent.read(profile: profile), .init())
        var consent = BrowserServiceConsent(); consent.filterUpdates = true
        try consent.write(profile: profile)
        XCTAssertEqual(BrowserServiceConsent.read(profile: profile), consent)
        let profileAttributes = try FileManager.default.attributesOfItem(atPath: profile.path)
        XCTAssertEqual((profileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let consentAttributes = try FileManager.default.attributesOfItem(atPath: profile.appendingPathComponent("winmux-services.json").path)
        XCTAssertEqual((consentAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try Data("{}".utf8).write(to: profile.appendingPathComponent("winmux-services.json"))
        XCTAssertEqual(BrowserServiceConsent.read(profile: profile), .init())
    }
}
