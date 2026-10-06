import BridgeCore
import Foundation
import WorkspaceCore
import XCTest

final class WorkspaceActivationTests: XCTestCase {
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

    func testFreshStartPreparesPrivateDirectoriesBeforeSavingConsent() throws {
        let parent = try directory(), store = try WorkspaceActivationStore(root: parent.appendingPathComponent("workspace"))
        let request = try WorkspaceActivation(browser: URL(fileURLWithPath: "/Applications/Example.app"))
        var consent = BrowserServiceConsent()
        consent.securityUpdates = true
        consent.filterUpdates = true
        let lock = try store.lock()
        defer { withExtendedLifetime(lock) {} }
        try store.writeRequest(request, consent: consent)
        try store.writeStatus(.init(requestID: request.id, phase: "starting", helperPID: 0, helperLaunch: nil))
        XCTAssertEqual(try store.readRequest(), request)
        XCTAssertEqual(try store.readStatus()?.requestID, request.id)
        XCTAssertEqual(BrowserServiceConsent.read(profile: request.profile(in: store.root)), consent)
        for url in [store.root, request.directory(in: store.root), request.profile(in: store.root)] {
            XCTAssertEqual(try permissions(url), 0o700)
        }
        XCTAssertEqual(try permissions(request.profile(in: store.root).appendingPathComponent("winmux-services.json")), 0o600)
    }

    func testStartRepairsRC1DirectoriesAndPreservesProfileContents() throws {
        let parent = try directory(), store = try WorkspaceActivationStore(root: parent.appendingPathComponent("workspace"))
        let request = try WorkspaceActivation(browser: URL(fileURLWithPath: "/Applications/Example.app"))
        let lock = try store.lock()
        defer { withExtendedLifetime(lock) {} }
        let daily = request.directory(in: store.root), profile = request.profile(in: store.root)
        let fm = FileManager.default
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        for url in [daily, profile] { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        var consent = BrowserServiceConsent()
        consent.extensionUpdates = true
        let consentFile = profile.appendingPathComponent("winmux-services.json")
        // Reproduce the old writer rather than using the corrected one.
        try JSONEncoder().encode(consent).write(to: consentFile, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: consentFile.path)
        let sentinel = profile.appendingPathComponent("existing-profile-data")
        try Data("preserve these bytes".utf8).write(to: sentinel)
        let sentinelPermissions = try permissions(sentinel)
        for _ in 0..<2 { try store.writeRequest(request, consent: consent) }
        XCTAssertEqual(try store.readRequest(), request)
        XCTAssertEqual(BrowserServiceConsent.read(profile: profile), consent)
        XCTAssertEqual(try permissions(daily), 0o700)
        XCTAssertEqual(try permissions(profile), 0o700)
        XCTAssertEqual(try permissions(consentFile), 0o600)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve these bytes".utf8))
        XCTAssertEqual(try permissions(sentinel), sentinelPermissions)
    }

    func testRecoveryRejectsExternallyWritableDirectoriesWithoutChangingThem() throws {
        for unsafeProfile in [false, true] {
            let parent = try directory(), store = try WorkspaceActivationStore(root: parent.appendingPathComponent("workspace"))
            let request = try WorkspaceActivation(browser: URL(fileURLWithPath: "/Applications/Example.app"))
            try store.prepareDirectories(for: request)
            let unsafe = unsafeProfile ? request.profile(in: store.root) : request.directory(in: store.root)
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: unsafe.path)
            XCTAssertThrowsError(try store.writeRequest(request, consent: .init()))
            XCTAssertEqual(try permissions(unsafe), 0o777)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("request.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: request.profile(in: store.root).appendingPathComponent("winmux-services.json").path))
        }
    }

    func testRecoveryRejectsLinkedWorkspaceOrProfileWithoutTouchingTarget() throws {
        for linkedProfile in [false, true] {
            let parent = try directory(), store = try WorkspaceActivationStore(root: parent.appendingPathComponent("workspace"))
            let request = try WorkspaceActivation(browser: URL(fileURLWithPath: "/Applications/Example.app"))
            try store.prepare()
            let target = parent.appendingPathComponent("unrelated")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            let sentinel = target.appendingPathComponent("sentinel")
            try Data("keep".utf8).write(to: sentinel)
            if linkedProfile {
                try FileManager.default.createDirectory(at: request.directory(in: store.root), withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
            }
            let link = linkedProfile ? request.profile(in: store.root) : request.directory(in: store.root)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertThrowsError(try store.writeRequest(request, consent: .init()))
            XCTAssertEqual(try permissions(target), 0o755)
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["sentinel"])
        }
    }

    func testRecoveryDoesNotAdoptAnUnmarkedRoot() throws {
        let root = try directory()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let store = try WorkspaceActivationStore(root: root)
        let request = try WorkspaceActivation(browser: URL(fileURLWithPath: "/Applications/Example.app"))
        XCTAssertThrowsError(try store.writeRequest(request, consent: .init()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    private func permissions(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue
    }
}
