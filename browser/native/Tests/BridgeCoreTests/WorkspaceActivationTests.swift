@testable import BridgeCore
import Foundation
import XCTest

final class WorkspaceActivationTests: XCTestCase {
    func testViewsTrialUsesSeparateProfileStateAndActivationFiles() throws {
        let daily = WorkspaceActivationStore.root(forViewsTrial: false)
        let trial = WorkspaceActivationStore.root(forViewsTrial: true)
        XCTAssertNotEqual(daily, trial)
        XCTAssertEqual(daily.lastPathComponent, "WinMux Browser Workspace Alpha")
        XCTAssertEqual(trial.lastPathComponent, "WinMux Browser Views Trial")
        let request = try WorkspaceActivation(browser: URL(fileURLWithPath: "/Applications/WinMux Browser Views Trial.app"))
        XCTAssertNotEqual(request.profile(in: daily), request.profile(in: trial))
        XCTAssertNotEqual(request.nativeState(in: daily), request.nativeState(in: trial))
    }
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: path) }
        return path
    }

    func testValidationRequiresCompleteLaunchBoundScope() throws {
        let app = URL(fileURLWithPath: "/Applications/Example.app")
        XCTAssertThrowsError(try WorkspaceActivation(browser: app, validationID: UUID()))
        XCTAssertThrowsError(try WorkspaceActivation(browser: app, nativeProcessID: 42, nativeProcessLaunch: Date()))
        XCTAssertThrowsError(try WorkspaceActivation(browser: app, validationID: UUID(), nativeProcessID: -1, nativeProcessLaunch: Date()))
        let request = try WorkspaceActivation(browser: app, validationID: UUID(), nativeProcessID: 42, nativeProcessLaunch: Date(),
                                              testService: SigningIdentity.serviceName + ".test." + UUID().uuidString)
        let root = try directory()
        XCTAssertTrue(request.profile(in: root).path.hasPrefix(root.path + "/validation/"))
        let normal = try WorkspaceActivation(browser: app)
        XCTAssertEqual(normal.nativeState(in: root).path, root.path + "/daily/native-state")
    }

    func testStoreIsPrivateAndPreservesRequestAndProfile() throws {
        let parent = try directory(), store = try WorkspaceActivationStore(root: parent.appendingPathComponent("workspace"))
        XCTAssertNil(try store.readRequest())
        let request = try WorkspaceActivation(browser: URL(fileURLWithPath: "/Applications/Example.app"))
        try store.writeRequest(request)
        let sentinel = request.profile(in: store.root).appendingPathComponent("sentinel")
        try Data("preserved".utf8).write(to: sentinel)
        try store.prepareDirectories(for: request)
        XCTAssertEqual(try store.readRequest(), request)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "preserved")
        let attrs = try FileManager.default.attributesOfItem(atPath: store.root.appendingPathComponent("request.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let lock = try store.lock()
        XCTAssertThrowsError(try store.lock())
        withExtendedLifetime(lock) {}
    }

    func testUnmarkedAndSymlinkDirectoriesAreRejectedWithoutWriting() throws {
        let parent = try directory()
        let unmarked = try WorkspaceActivationStore(root: parent)
        XCTAssertThrowsError(try unmarked.prepare())
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: parent)
        XCTAssertThrowsError(try WorkspaceActivationStore(root: link))
        let store = try WorkspaceActivationStore(root: parent.appendingPathComponent("workspace"))
        try store.prepare()
        let target = parent.appendingPathComponent("untouched")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: store.root.appendingPathComponent("request.json"), withDestinationURL: target)
        XCTAssertThrowsError(try store.writeRequest(WorkspaceActivation(browser: URL(fileURLWithPath: "/Applications/Example.app"))))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }

    func testDecodedRequestsCannotWidenValidationScope() throws {
        let request = try WorkspaceActivation(browser: URL(fileURLWithPath: "/Applications/Example.app"),
                                              validationID: UUID(), nativeProcessID: 42, nativeProcessLaunch: Date(),
                                              testService: SigningIdentity.serviceName + ".test." + UUID().uuidString)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        json.removeValue(forKey: "nativeProcessID")
        let decoded = try JSONDecoder().decode(WorkspaceActivation.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try decoded.validate())
    }
}
