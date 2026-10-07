@testable import AppBundle
import Foundation
import WorkspaceCore
import XCTest

@MainActor final class BrowserProfileMovesTest: XCTestCase {
    @MainActor final class Fixture {
        let controller = BrowserWorkspaceController()
        let connection = UUID(), epoch = UUID()
        let source: Workspace, destination: Workspace
        let work: WorkspaceBrowserProfile, personal: WorkspaceBrowserProfile
        var records: [BrowserTabRecord] = []
        var requests: [BrowserNewTabRequest] = []
        var replies: [@MainActor (BrowserActionReply, SurfaceID?) -> Void] = []
        var actions: [BrowserActionRequest] = []
        var revision: UInt64 = 0

        init() throws {
            setUpWorkspacesForTests()
            source = focus.workspace
            let space = createWorkspaceProject()
            destination = try XCTUnwrap(Workspace.all.first { $0.projectId == space.id && !$0.isPinnedGroup })
            work = try controller.createBrowserProfile(named: "Work", for: source.projectId)
            personal = try controller.createBrowserProfile(named: "Personal", for: destination.projectId)
            controller.usesSurfaceTree = true
            controller.connected(connection, processID: -1, sendNewTab: { [weak self] request, reply in
                self?.requests.append(request); self?.replies.append(reply)
            }, send: { [weak self] request, reply in self?.actions.append(request); reply(.issued) })
            publish()
        }

        func publish() {
            revision += 1
            controller.received(.init(revision: revision, full: true, tabs: records), epoch: epoch,
                                connection: connection, protocolVersion: 8)
        }

        func add(profile: UUID? = nil, shared: Bool = false, url: String = "https://example.test/account") -> SurfaceID {
            let id = SurfaceID.browserTab(profile: profile ?? work.id, tab: UUID())
            var record = BrowserTabRecord(surfaceID: id, hostID: id.description, title: "Account", selected: false, url: url)
            record.isSharedProfile = shared
            records.append(record); publish()
            controller.placeCreatedBrowserTab(id, in: source.name, focusAddress: false, selectCreated: false, focusGeneration: 0)
            return id
        }

        func replacement(_ index: Int = 0, inventoryFirst: Bool = true, shared: Bool = false) -> SurfaceID {
            let id = SurfaceID.browserTab(profile: requests[index].workspaceProfile?.profileID ?? UUID(), tab: UUID())
            var record = BrowserTabRecord(surfaceID: id, hostID: id.description, title: "Account", selected: false, url: requests[index].url ?? "")
            record.isSharedProfile = shared
            if !inventoryFirst { replies[index](.issued, id) }
            records.append(record); publish()
            if inventoryFirst { replies[index](.issued, id) }
            return id
        }

        var closed: Set<SurfaceID> { Set(actions.filter { $0.action == .close }.map(\.surfaceID)) }
        func stop() { controller.disconnected(connection) }
    }

    func testDivergentVersionSixOwnersCannotReceiveNewFeatureMessages() throws {
        for version in [6, 7, 8] {
            setUpWorkspacesForTests()
            let c = BrowserWorkspaceController(), connection = UUID()
            let id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
            c.connected(connection, processID: -1, send: { _, reply in reply(.issued) })
            c.received(.init(revision: 1, full: true, tabs: [.init(surfaceID: id, hostID: "host", title: "Test", selected: false)]),
                epoch: UUID(), connection: connection, protocolVersion: version)
            let session = try XCTUnwrap(c.owner(of: id))
            XCTAssertEqual(session.supportsWorkspaceProfiles, version >= 7)
            XCTAssertEqual(session.supportsPrivacy, version >= 8)
            c.disconnected(connection)
        }
    }

    func testCrossProfileMoveWaitsForBothReplyAndInventoryAndKeepsSourceUntilClose() throws {
        for inventoryFirst in [true, false] {
            let f = try Fixture(); defer { f.stop() }
            let old = f.add()
            f.controller.reconcileSavedViews()
            let memberID = try XCTUnwrap(f.controller.savedMemberID(for: old))
            XCTAssertTrue(moveSidebarSurface(old, to: f.destination, controller: f.controller))
            XCTAssertEqual(f.requests.first?.workspaceProfile, .named(f.personal))
            XCTAssertEqual(f.requests.first?.url, "https://example.test/account")
            XCTAssertNil(f.requests.first?.sourceSurfaceID)
            XCTAssertEqual(f.controller.workspaceName(for: old), f.source.name)
            XCTAssertTrue(f.closed.isEmpty)
            let new = f.replacement(inventoryFirst: inventoryFirst)
            XCTAssertEqual(f.controller.workspaceName(for: new), f.destination.name)
            XCTAssertEqual(f.controller.workspaceName(for: old), f.source.name)
            XCTAssertEqual(f.closed, [old])
            XCTAssertTrue(f.controller.pendingProfileMoves.isEmpty)
            f.records.removeAll { $0.surfaceID == old }; f.publish()
            XCTAssertNil(f.controller.workspaceName(for: old))
            XCTAssertEqual(f.controller.surfaceTree.workspace(of: new), f.destination.name)
            XCTAssertNoThrow(try f.controller.capturePlacementSnapshot()?.validated())
            XCTAssertEqual(f.controller.savedMemberID(for: new), memberID)
        }
    }

    func testSameNamedAndSharedProfilesMoveWithoutReopening() throws {
        for shared in [false, true] {
            let f = try Fixture(); defer { f.stop() }
            try f.controller.setBrowserProfile(shared ? nil : f.work.id, for: f.destination.projectId)
            let old = f.add(shared: shared)
            XCTAssertTrue(moveSidebarSurface(old, to: f.destination, controller: f.controller))
            XCTAssertTrue(f.requests.isEmpty)
            XCTAssertTrue(f.closed.isEmpty)
            XCTAssertEqual(f.controller.workspaceName(for: old), f.destination.name)
        }
    }

    func testNamedToSharedUsesExplicitSharedRouting() throws {
        let f = try Fixture(); defer { f.stop() }
        try f.controller.setBrowserProfile(nil, for: f.destination.projectId)
        let old = f.add()
        XCTAssertTrue(moveSidebarSurface(old, to: f.destination, controller: f.controller))
        XCTAssertEqual(f.requests.first?.workspaceProfile, .shared)
        let new = f.replacement(shared: true)
        XCTAssertEqual(f.controller.workspaceName(for: new), f.destination.name)
        XCTAssertEqual(f.closed, [old])
    }

    func testSameSpaceReorganizationDoesNotChangeExistingTabsAfterDefaultChanges() throws {
        let f = try Fixture(); defer { f.stop() }
        let old = f.add()
        try f.controller.setBrowserProfile(f.personal.id, for: f.source.projectId)
        let other = Workspace.get(byName: "Another view"); other.assignProject(f.source.projectId)
        XCTAssertTrue(moveSidebarSurface(old, to: other, controller: f.controller))
        XCTAssertTrue(f.requests.isEmpty)
        XCTAssertEqual(f.controller.workspaceName(for: old), other.name)
    }

    func testWrongProfileReplyCannotCloseOriginalAndDisconnectCancelsPendingMove() throws {
        let f = try Fixture()
        let old = f.add()
        XCTAssertTrue(moveSidebarSurface(old, to: f.destination, controller: f.controller))
        f.replies[0](.issued, .browserTab(profile: f.work.id, tab: UUID()))
        XCTAssertTrue(f.closed.isEmpty)
        XCTAssertTrue(f.controller.pendingProfileMoves.isEmpty)
        XCTAssertEqual(f.controller.workspaceName(for: old), f.source.name)
        XCTAssertTrue(moveSidebarSurface(old, to: f.destination, controller: f.controller))
        f.stop()
        XCTAssertTrue(f.controller.pendingProfileMoves.isEmpty)
        XCTAssertTrue(f.closed.isEmpty)
        XCTAssertEqual(f.controller.workspaceName(for: old), f.source.name)
    }

    func testFailedCreationAndDuplicateMoveLeaveOriginalUntouched() throws {
        let f = try Fixture(); defer { f.stop() }
        let old = f.add()
        XCTAssertTrue(moveSidebarSurface(old, to: f.destination, controller: f.controller))
        XCTAssertFalse(moveSidebarSurface(old, to: f.destination, controller: f.controller))
        XCTAssertEqual(f.requests.count, 1)
        f.replies[0](.unavailable, nil)
        XCTAssertEqual(f.controller.workspaceName(for: old), f.source.name)
        XCTAssertTrue(f.closed.isEmpty)
        XCTAssertTrue(f.controller.pendingProfileMoves.isEmpty)
    }

    func testChangedDestinationProfileOrSourceNavigationCancelsMove() throws {
        for profileChange in [true, false] {
            let f = try Fixture(); defer { f.stop() }
            let old = f.add()
            XCTAssertTrue(moveSidebarSurface(old, to: f.destination, controller: f.controller))
            if profileChange { try f.controller.setBrowserProfile(nil, for: f.destination.projectId) }
            else {
                f.records[0] = .init(surfaceID: old, hostID: old.description, title: "New", selected: false, url: "https://example.test/changed")
                f.publish()
            }
            let copy = f.replacement()
            XCTAssertEqual(f.controller.workspaceName(for: old), f.source.name)
            XCTAssertFalse(f.closed.contains(old))
            XCTAssertTrue(f.closed.contains(copy))
        }
    }

    func testGroupMoveCommitsAllReplacementsTogetherAndRetainsSplitIdentity() throws {
        let f = try Fixture(); defer { f.stop() }
        let a = f.add(), b = f.add(url: "https://example.test/second")
        XCTAssertTrue(f.controller.editOrganization(of: a) { $0.group(a, with: b, layout: .horizontal) })
        let group = try XCTUnwrap(f.controller.surfaceTree.containingGroup(of: a))
        XCTAssertTrue(f.controller.moveGroup(group, to: f.destination))
        XCTAssertEqual(f.requests.count, 2)
        let first = f.replacement(0)
        XCTAssertEqual(f.controller.workspaceName(for: a), f.source.name)
        XCTAssertTrue(f.closed.isEmpty)
        let second = f.replacement(1)
        XCTAssertEqual(f.controller.workspaceName(forGroup: group), f.destination.name)
        XCTAssertEqual(Set(f.controller.surfaceTree.group(group)?.surfaces ?? []), [first, second])
        XCTAssertEqual(f.controller.sidebarGroupLayout(group), .horizontal)
        XCTAssertEqual(f.closed, [a, b])
    }

    func testGroupFailureClosesOnlyCopiesEvenWithLateCreationReply() throws {
        let f = try Fixture(); defer { f.stop() }
        let a = f.add(), b = f.add()
        XCTAssertTrue(f.controller.editOrganization(of: a) { $0.group(a, with: b, layout: .stack) })
        let group = try XCTUnwrap(f.controller.surfaceTree.containingGroup(of: a))
        XCTAssertTrue(f.controller.moveGroup(group, to: f.destination))
        f.replies[0](.unavailable, nil)
        let late = f.replacement(1, inventoryFirst: false)
        XCTAssertEqual(f.controller.workspaceName(forGroup: group), f.source.name)
        XCTAssertEqual(f.closed, [late])
    }

    func testLiveAndClosedPinsAdoptDestinationProfileAndKeepShortcutIdentity() throws {
        for live in [true, false] {
            let f = try Fixture(); defer { f.stop() }
            let old = f.add()
            XCTAssertTrue(f.controller.pinBrowserTab(old))
            let pin = try XCTUnwrap(f.controller.sidebarPin(for: old))
            if !live { f.records.removeAll(); f.publish() }
            XCTAssertTrue(f.controller.movePin(pin.id, to: f.destination.projectId))
            let new = f.replacement()
            let moved = try XCTUnwrap(f.controller.browserSidebarPins.first { $0.id == pin.id })
            XCTAssertEqual(moved.profileID, f.personal.id)
            XCTAssertEqual(moved.surfaceID, new)
            XCTAssertEqual(moved.url, pin.url)
            XCTAssertEqual(Workspace.existing(byName: moved.workspaceName)?.projectId, f.destination.projectId)
            XCTAssertEqual(f.closed, live ? [old] : [])
            XCTAssertNoThrow(try XCTUnwrap(f.controller.capturePlacementSnapshot()).validated())
        }
    }

    func testPinnedSplitMovesAcrossProfilesOnlyAfterAllPagesAreReady() throws {
        let f = try Fixture(); defer { f.stop() }
        let a = f.add(), b = f.add(url: "https://example.test/second")
        XCTAssertTrue(f.controller.editOrganization(of: a) { $0.group(a, with: b, layout: .horizontal) })
        let group = try XCTUnwrap(f.controller.surfaceTree.containingGroup(of: a))
        XCTAssertTrue(f.controller.pinSurfaceGroup(group))
        let desktop = try XCTUnwrap(f.controller.pinnedViews.first)
        XCTAssertTrue(f.controller.movePin(desktop.id, to: f.destination.projectId))
        XCTAssertEqual(f.requests.count, 2)
        let first = f.replacement(0)
        XCTAssertEqual(f.controller.pinnedViews.first?.spaceID, f.source.projectId.rawValue)
        XCTAssertTrue(f.closed.isEmpty)
        let second = f.replacement(1)
        let moved = try XCTUnwrap(f.controller.pinnedViews.first)
        XCTAssertEqual(moved.id, desktop.id)
        XCTAssertEqual(moved.spaceID, f.destination.projectId.rawValue)
        XCTAssertEqual(Set(f.controller.surfaceTree.group(group)?.surfaces ?? []), [first, second])
        XCTAssertEqual(f.controller.surfaceTree.layouts[group], .horizontal)
        XCTAssertEqual(f.closed, [a, b])
        XCTAssertEqual(f.controller.browserSidebarPins.map(\.profileID), [f.personal.id, f.personal.id])
        XCTAssertNoThrow(try f.controller.capturePlacementSnapshot()?.validated())
    }

    func testFocusFollowsReplacementOnlyWhenRequested() throws {
        for follows in [true, false] {
            let f = try Fixture(); defer { f.stop() }
            let old = f.add()
            _ = f.controller.select(old)
            XCTAssertTrue(moveSurfaceToWorkspace(old, f.destination, CmdIo(stdin: .emptyStdin),
                focusFollowsSurface: follows, failIfNoop: false, controller: f.controller))
            let new = f.replacement()
            if follows { XCTAssertEqual(f.controller.focusCoordinator.target, new) }
            else { XCTAssertNotEqual(f.controller.focusCoordinator.target, new); XCTAssertEqual(focus.workspace, f.source) }
        }
    }

    func testLaterSelectionWinsOverDelayedMoveFocus() throws {
        let f = try Fixture(); defer { f.stop() }
        let old = f.add(), other = f.add()
        _ = f.controller.select(old)
        XCTAssertTrue(moveSurfaceToWorkspace(old, f.destination, CmdIo(stdin: .emptyStdin),
            focusFollowsSurface: true, failIfNoop: false, controller: f.controller))
        _ = f.controller.select(other)
        _ = f.replacement()
        XCTAssertEqual(f.controller.focusCoordinator.target, other)
    }

    func testOrderedCrossSpaceMoveKeepsItsRequestedPosition() throws {
        let f = try Fixture(); defer { f.stop() }
        let old = f.add(), target = f.add(profile: f.personal.id)
        f.controller.moveBrowserSurface(target, to: f.destination.name)
        f.controller.organize(old, before: target)
        let new = f.replacement()
        XCTAssertEqual(f.controller.surfaceTree.roots[f.destination.name]?.flatMap(\.surfaces), [new, target])
        XCTAssertEqual(f.closed, [old])
    }
}
