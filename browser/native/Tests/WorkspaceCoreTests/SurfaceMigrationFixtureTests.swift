import Foundation
import XCTest
@testable import WorkspaceCore

/// Fixed pre-migration bytes protect compatibility independently of the current encoder.
final class SurfaceMigrationFixtureTests: XCTestCase {
    private func fixture(_ name: String) throws -> SurfaceWorkspaceSnapshot {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: Data(contentsOf: url)).validated()
    }

    func testSharedLayoutRetainsMixedMembersSelectionAndProportions() throws {
        let snapshot = try fixture("shared-layout-v4")
        let group = try XCTUnwrap(snapshot.tree.roots["Research"]?.first)
        XCTAssertEqual(group.surfaces.count, 2)
        XCTAssertEqual(snapshot.selected, group.surfaces.last)
        XCTAssertEqual(snapshot.tree.weights[group.surfaces[0].description], 2)
        XCTAssertEqual(snapshot.tree.weights[group.surfaces[1].description], 3)
        XCTAssertTrue(snapshot.tree.layouts.values.allSatisfy { $0 == .horizontal })
        XCTAssertEqual(try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }

    func testPinnedArrangementRetainsClosedMemberAndSavedLaunchInformation() throws {
        let snapshot = try fixture("pinned-arrangement-v5")
        let desktop = try XCTUnwrap(snapshot.pinnedDesktops.first)
        let page = try XCTUnwrap(snapshot.browserPins.first)
        XCTAssertNil(page.surfaceID)
        XCTAssertEqual(page.url, "https://example.com/reference")
        XCTAssertEqual(desktop.memberIDs.count, 2)
        XCTAssertEqual(desktop.layout.flatMap(\.members), desktop.memberIDs)
        XCTAssertEqual(desktop.selectedMember, page.id)
        XCTAssertEqual(desktop.formerRegularIndex, 2)
        XCTAssertEqual(snapshot.pinShelves.first?.desktopOrder, [desktop.id])
        XCTAssertEqual(snapshot.tree.roots[desktop.workspaceName]?.flatMap(\.surfaces).count, 1)
        XCTAssertEqual(try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }
}
