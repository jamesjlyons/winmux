import Foundation
import XCTest
@testable import WorkspaceCore

final class SavedViewTests: XCTestCase {
    private func fixture() throws -> (SurfaceWorkspaceSnapshot, SavedView) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "pinned-arrangement-v5", withExtension: "json", subdirectory: "Fixtures"))
        let snapshot = try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: Data(contentsOf: url)).validated()
        let desktop = try XCTUnwrap(snapshot.pinnedDesktops.first)
        let view = try XCTUnwrap(desktop.savedView(browserPins: snapshot.browserPins, appPins: snapshot.appPins))
        return (snapshot, view)
    }

    func testLegacyPinConversionPreservesClosedSlotsAndLaunchDescriptors() throws {
        let (snapshot, view) = try fixture()
        let desktop = try XCTUnwrap(snapshot.pinnedDesktops.first)
        XCTAssertEqual(view.id, desktop.id)
        XCTAssertEqual(view.members.map(\.id), desktop.memberIDs)
        XCTAssertEqual(view.layout, desktop.layout)
        XCTAssertEqual(view.selectedMember, desktop.selectedMember)
        XCTAssertEqual(view.formerRegularIndex, desktop.formerRegularIndex)
        XCTAssertEqual(view.members.last?.launch, .browser(profileID: snapshot.browserPins[0].profileID, url: "https://example.com/reference"))
        XCTAssertNil(view.members.last?.surfaceID)
        XCTAssertEqual(try JSONDecoder().decode(SavedView.self, from: JSONEncoder().encode(view)), view)
    }

    func testCloseAndRebindPreserveSavedLayoutAndSelection() throws {
        let (snapshot, saved) = try fixture()
        var view = saved
        let native = try XCTUnwrap(view.members.first?.surfaceID)
        let pageMember = try XCTUnwrap(view.members.last?.id)
        let newPage = SurfaceID.browserTab(profile: snapshot.browserPins[0].profileID, tab: UUID())
        view.captureLayout(from: snapshot.tree, selected: nil)
        XCTAssertEqual(view.layout, saved.layout)
        XCTAssertTrue(view.bind(pageMember, to: newPage))
        let live = view.liveLayout(available: [native, newPage])
        let group = try XCTUnwrap(live.containingGroup(of: newPage))
        XCTAssertEqual(live.group(group)?.surfaces, [native, newPage])
        XCTAssertEqual(live.weights[native.description], 2)
        XCTAssertEqual(live.weights[newPage.description], 3)
        XCTAssertEqual(live.activeSurfaces[group], newPage)

        XCTAssertTrue(view.bind(pageMember, to: nil))
        view.captureLayout(from: view.liveLayout(available: [native]), selected: nil)
        XCTAssertEqual(view.layout, saved.layout)
        XCTAssertEqual(view.selectedMember, pageMember)
        XCTAssertTrue(view.liveLayout(available: []).roots[view.workspaceName]?.isEmpty == true)
        XCTAssertEqual(view.members.map(\.id), saved.members.map(\.id))
    }

    func testBindingsRejectWrongProfilesKindsAndDuplicateOwnersAtomically() throws {
        var (_, view) = try fixture()
        let before = view
        let nativeMember = view.members[0].id, pageMember = view.members[1].id
        XCTAssertFalse(view.bind(pageMember, to: .browserTab(profile: UUID(), tab: UUID())))
        XCTAssertFalse(view.bind(pageMember, to: view.members[0].surfaceID))
        XCTAssertFalse(view.bind(nativeMember, to: .browserTab(profile: UUID(), tab: UUID())))
        XCTAssertFalse(view.bind(UUID(), to: nil))
        XCTAssertEqual(view, before)

        let native = try XCTUnwrap(view.members[0].surfaceID)
        let other = ViewMember(title: "Other app", launch: view.members[0].launch)
        view.members.append(other)
        let withOther = view
        XCTAssertFalse(view.bind(other.id, to: native))
        XCTAssertEqual(view, withOther)
    }

    func testRegularEmptyViewAndReferenceOnlyLayoutUseTheSameModel() throws {
        var view = SavedView(spaceID: "work", workspaceName: "Empty", title: "Empty")
        XCTAssertTrue(view.isValid)
        let native = SurfaceID.nativeWindow(UUID())
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        view.members = [.init(title: "Editor", surfaceID: native), .init(title: "Page", surfaceID: page)]
        var live = SurfaceTree()
        live.reconcile([native, page], in: view.workspaceName)
        XCTAssertTrue(live.group(page, with: native, layout: .horizontal))
        view.captureLayout(from: live, selected: page)
        XCTAssertTrue(view.isValid)
        XCTAssertTrue(view.members.allSatisfy { $0.launch == nil })
        XCTAssertEqual(view.liveLayout(available: [native, page]).roots, live.roots)
        XCTAssertEqual(try JSONDecoder().decode(SavedView.self, from: JSONEncoder().encode(view)), view)
        view.isPinned = true
        XCTAssertFalse(view.isValid, "Pinning requires explicit launch descriptors")
    }

    func testConversionRejectsMissingMembersAndInvalidLayoutReferences() throws {
        let (snapshot, saved) = try fixture()
        XCTAssertNil(snapshot.pinnedDesktops[0].savedView(browserPins: [], appPins: snapshot.appPins))
        var view = saved
        view.members.append(view.members[0])
        XCTAssertFalse(view.isValid)
        view = saved
        view.layout.append(.member(UUID(), 1))
        XCTAssertFalse(view.isValid)
        view = saved
        view.selectedMember = UUID()
        XCTAssertFalse(view.isValid)
    }
}
