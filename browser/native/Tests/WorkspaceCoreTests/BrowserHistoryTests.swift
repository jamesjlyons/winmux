import Foundation
import WorkspaceCore
import XCTest

@MainActor
final class BrowserHistoryTests: XCTestCase {
    func testValidatesHistoryURLsAndPayloadBounds() {
        XCTAssertTrue(BrowserHistoryEntry(url: "https://example.com/path", title: "Example").isValid)
        for url in ["javascript:alert(1)", "file:///secret", "https://name:password@example.com/", "https://", String(repeating: "a", count: 8193)] {
            XCTAssertFalse(BrowserHistoryEntry(url: url, title: "").isValid)
        }
        XCTAssertFalse(BrowserHistoryEntry(url: "https://example.com", title: "", lastVisit: .infinity).isValid)
    }

    func testQueryRequiresCapabilityAndRegularProfileAndRejectsLateEpochs() {
        let id = SurfaceID.browserTab(profile: UUID(), tab: UUID()), epoch = UUID()
        var requests: [BrowserHistoryRequest] = []
        var reply: (@MainActor ([BrowserHistoryEntry]) -> Void)?
        let session = BrowserSurfaceSession(sendHistory: { requests.append($0); reply = $1 }) { _, _ in }
        session.connect(epoch: epoch)
        let tab = BrowserTabRecord(surfaceID: id, hostID: "host", title: "", selected: true)
        XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: [tab]), epoch: epoch))
        session.queryHistory("git", surfaceID: id) { XCTAssertTrue($0.isEmpty) }
        XCTAssertTrue(requests.isEmpty)
        session.supportsHistory = true
        var result: [BrowserHistoryEntry] = []
        session.queryHistory("git", surfaceID: id) { result = $0 }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].surfaceID, id)
        let history = [BrowserHistoryEntry(url: "https://github.com/", title: "GitHub")]
        reply?(history)
        XCTAssertEqual(result, history)
        session.connect(epoch: UUID())
        reply?(history)
        XCTAssertTrue(result.isEmpty)
        let privateID = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let privateTab = BrowserTabRecord(surfaceID: privateID, hostID: "private", title: "", selected: true, privateBrowsing: true)
        XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: [privateTab]), epoch: session.epoch!))
        session.queryHistory("git", surfaceID: privateID) { XCTAssertTrue($0.isEmpty) }
        XCTAssertEqual(requests.count, 1)
    }
}
