import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceIDTests: XCTestCase {
    func testKindsAndProfilesHaveSeparateNamespaces() throws {
        let id = UUID(), work = UUID(), personal = UUID()
        let identities: Set<SurfaceID> = [.nativeWindow(id), .browserTab(profile: work, tab: id), .browserTab(profile: personal, tab: id)]
        XCTAssertEqual(identities.count, 3)
        for identity in identities {
            XCTAssertEqual(SurfaceID(string: identity.description), identity)
            XCTAssertEqual(try JSONDecoder().decode(SurfaceID.self, from: JSONEncoder().encode(identity)), identity)
        }
    }

    func testNumericAndMalformedIdentitiesAreRejected() {
        for string in ["42", "native:42", "browser::", "browser:\(UUID())", "native:\(UUID()):extra", "unknown:\(UUID())"] {
            XCTAssertNil(SurfaceID(string: string))
            XCTAssertThrowsError(try JSONDecoder().decode(SurfaceID.self, from: JSONEncoder().encode(string)))
        }
    }

    func testNativeItemsDoNotAdvertiseBrowserActions() {
        XCTAssertTrue(SurfaceCapabilities.nativeWindow.contains([.focus, .close, .move, .resize]))
        XCTAssertTrue(SurfaceCapabilities.nativeWindow.intersection([.navigate, .reload, .duplicate, .mute]).isEmpty)
        XCTAssertTrue(SurfaceCapabilities.browserTab.contains([.navigate, .reload, .duplicate, .mute]))
    }
}
