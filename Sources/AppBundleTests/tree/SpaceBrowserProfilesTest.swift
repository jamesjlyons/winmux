@testable import AppBundle
import Foundation
import WorkspaceCore
import XCTest

@MainActor final class SpaceBrowserProfilesTest: XCTestCase {
    func testNamedProfilesCanBeSharedAcrossSpacesAndPersistByStableIdentity() throws {
        setUpWorkspacesForTests()
        let controller = BrowserWorkspaceController()
        controller.usesSurfaceTree = true
        let first = focus.workspace.projectId, second = createWorkspaceProject().id
        let profile = try controller.createBrowserProfile(named: " Work ", for: first)
        try controller.setBrowserProfile(profile.id, for: second)
        try renameWorkspaceProject(first, displayName: "Renamed Space")
        let snapshot = try XCTUnwrap(controller.capturePlacementSnapshot()).validated()
        let restored = BrowserWorkspaceController()
        restored.restorePlacementSnapshot(try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot)))
        XCTAssertEqual(restored.browserProfiles, [.init(id: profile.id, name: "Work")])
        XCTAssertEqual(try restored.browserProfileTarget(for: first), .named(profile))
        XCTAssertEqual(try restored.browserProfileTarget(for: second), .named(profile))
        try restored.setBrowserProfile(nil, for: first)
        XCTAssertEqual(try restored.browserProfileTarget(for: first), .shared)
        XCTAssertEqual(try restored.browserProfileTarget(for: second), .named(profile))
        XCTAssertEqual(restored.browserProfiles.count, 1)
    }

    func testNameValidationAndMissingBindingsCannotFallBackToShared() throws {
        setUpWorkspacesForTests()
        let controller = BrowserWorkspaceController(), space = focus.workspace.projectId
        _ = try controller.createBrowserProfile(named: "Work", for: space)
        for invalid in ["", "   ", "shared", "WORK", "line\nbreak", String(repeating: "x", count: 129)] {
            XCTAssertThrowsError(try controller.createBrowserProfile(named: invalid, for: space))
        }
        XCTAssertEqual(controller.browserProfiles.count, 1)
        controller.browserProfileBySpace[space.rawValue] = UUID()
        XCTAssertThrowsError(try controller.browserProfileTarget(for: space))
    }

    func testDeletingSpaceKeepsTheProfileAndOtherSpaceAssignment() throws {
        setUpWorkspacesForTests()
        let controller = BrowserWorkspaceController.shared
        let previousProfiles = controller.browserProfiles, previousBindings = controller.browserProfileBySpace
        defer { controller.browserProfiles = previousProfiles; controller.browserProfileBySpace = previousBindings }
        let remaining = focus.workspace.projectId, deleted = createWorkspaceProject().id
        let profile = try controller.createBrowserProfile(named: "Reusable test profile", for: deleted)
        try controller.setBrowserProfile(profile.id, for: remaining)
        try deleteWorkspaceProject(deleted)
        XCTAssertNil(controller.browserProfileBySpace[deleted.rawValue])
        XCTAssertEqual(try controller.browserProfileTarget(for: remaining), .named(profile))
        XCTAssertTrue(controller.browserProfiles.contains(profile))
    }

    func testNewTabsUseRequestedSpaceProfileInsteadOfFocusedPageAccount() throws {
        setUpWorkspacesForTests()
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
        let work = try controller.createBrowserProfile(named: "Work", for: focus.workspace.projectId)
        let requested = focus.workspace
        let personal = createWorkspaceProject()
        let destination = try XCTUnwrap(Workspace.all.first { $0.projectId == personal.id && !$0.isPinnedGroup })
        let personalProfile = try controller.createBrowserProfile(named: "Personal", for: personal.id)
        var requests: [BrowserNewTabRequest] = []
        controller.connected(connection, processID: -1, sendNewTab: { request, _ in requests.append(request) }, send: { _, reply in reply(.issued) })
        let other = SurfaceID.browserTab(profile: personalProfile.id, tab: UUID())
        controller.received(.init(revision: 1, full: true, tabs: [.init(surfaceID: other, hostID: "host", title: "", selected: true)]),
                            epoch: epoch, connection: connection, protocolVersion: 8)
        _ = controller.select(other)
        XCTAssertEqual(controller.openBrowserTab(workspaceName: requested.name), .issued)
        XCTAssertEqual(requests.last?.workspaceProfile, .named(work))
        XCTAssertNil(requests.last?.sourceSurfaceID)
        XCTAssertNil(requests.last?.profileID)
        XCTAssertEqual(controller.openBrowserTab(workspaceName: destination.name), .issued)
        XCTAssertEqual(requests.last?.workspaceProfile, .named(personalProfile))
        try controller.setBrowserProfile(nil, for: requested.projectId)
        XCTAssertEqual(controller.openBrowserTab(workspaceName: requested.name), .issued)
        XCTAssertEqual(requests.last?.workspaceProfile, .shared)
        XCTAssertNil(requests.last?.sourceSurfaceID)
        controller.disconnected(connection)
    }

    func testExplicitPinProfileRemainsAuthoritativeAfterSpaceProfileChanges() throws {
        setUpWorkspacesForTests()
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID(), pinnedProfile = UUID()
        _ = try controller.createBrowserProfile(named: "Work", for: focus.workspace.projectId)
        var request: BrowserNewTabRequest?
        controller.connected(connection, processID: -1, sendNewTab: { value, _ in request = value }, send: { _, _ in })
        controller.received(.init(revision: 1, full: true, tabs: []), epoch: epoch, connection: connection, protocolVersion: 8)
        XCTAssertEqual(controller.openBrowserTab(url: "https://example.test/", profileID: pinnedProfile, explicitPlacement: true), .issued)
        XCTAssertEqual(request?.profileID, pinnedProfile)
        XCTAssertNil(request?.workspaceProfile)
        controller.disconnected(connection)
    }

    func testLegacyBrowserRefusesNamedProfileWithoutSendingCreation() throws {
        setUpWorkspacesForTests()
        let controller = BrowserWorkspaceController(), connection = UUID()
        _ = try controller.createBrowserProfile(named: "Work", for: focus.workspace.projectId)
        controller.connected(connection, processID: -1, sendNewTab: { _, _ in XCTFail("Must not open another account") }, send: { _, _ in })
        controller.received(.init(revision: 1, full: true, tabs: []), epoch: UUID(), connection: connection, protocolVersion: 5)
        XCTAssertEqual(controller.openBrowserTab(), .unsupported)
        controller.disconnected(connection)
    }
}
