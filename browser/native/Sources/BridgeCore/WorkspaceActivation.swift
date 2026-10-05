import Darwin
import Foundation

/// An explicit, local activation request. This never imports a browser profile
/// or the standalone manager's configuration. Validation cannot widen to all apps.
public struct WorkspaceActivation: Codable, Equatable, Sendable {
    public static let serviceName = SigningIdentity.serviceName + ".managed"
    public let version: Int
    public let id: UUID
    public let browserPath: String
    public let validationID: UUID?
    public let nativeProcessID: Int32?
    public let nativeProcessLaunch: Date?
    public let machService: String

    public init(browser: URL, validationID: UUID? = nil, nativeProcessID: Int32? = nil,
                nativeProcessLaunch: Date? = nil, testService: String? = nil) throws {
        version = 1
        id = UUID()
        browserPath = browser.standardizedFileURL.path
        self.validationID = validationID
        self.nativeProcessID = nativeProcessID
        self.nativeProcessLaunch = nativeProcessLaunch
        machService = testService ?? Self.serviceName
        try validate()
    }

    public func validate() throws {
        let browser = URL(fileURLWithPath: browserPath)
        let prefix = SigningIdentity.serviceName + ".test."
        let testService = machService.hasPrefix(prefix) && UUID(uuidString: String(machService.dropFirst(prefix.count))) != nil
        guard version == 1, browserPath.hasPrefix("/"), browserPath.count < 4096,
              browser.standardizedFileURL.path == browserPath, browser.pathExtension == "app",
              (validationID == nil && nativeProcessID == nil && nativeProcessLaunch == nil && machService == Self.serviceName) ||
                (validationID != nil && (nativeProcessID ?? 0) > 0 && nativeProcessLaunch != nil && testService),
              nativeProcessLaunch.map({ $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 }) ?? true else {
            throw WorkspaceActivationError.invalidRequest
        }
    }

    public func directory(in root: URL) -> URL {
        root.appendingPathComponent(validationID.map { "validation/" + $0.uuidString } ?? "daily", isDirectory: true)
    }
    public func nativeState(in root: URL) -> URL { directory(in: root).appendingPathComponent("native-state") }
    public func profile(in root: URL) -> URL { directory(in: root).appendingPathComponent("browser-profile") }
}

public struct WorkspaceActivationStatus: Codable, Sendable {
    public let requestID: UUID
    public let phase: String
    public let helperPID: Int32
    public let helperLaunch: Date?
    public let detail: String
    public init(requestID: UUID, phase: String, helperPID: Int32, helperLaunch: Date?, detail: String = "") {
        self.requestID = requestID; self.phase = phase; self.helperPID = helperPID
        self.helperLaunch = helperLaunch; self.detail = detail
    }
}

public enum WorkspaceActivationError: LocalizedError {
    case invalidRequest, unsafeDirectory, busy, differentPackage, unavailable
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The workspace activation request is invalid."
        case .unsafeDirectory: "Workspace Setup requires its own marked, private directory."
        case .busy: "Another Workspace Setup operation is in progress."
        case .differentPackage: "This workspace belongs to a different browser package. Stop it from that package before changing versions."
        case .unavailable: "The workspace is not running. Start it before opening the managed browser."
        }
    }
}

public final class WorkspaceActivationLock {
    private let descriptor: Int32
    fileprivate init(url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw WorkspaceActivationError.unsafeDirectory }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw WorkspaceActivationError.busy
        }
    }
    deinit { close(descriptor) }
}

public struct WorkspaceActivationStore: Sendable {
    public let root: URL
    public static var isViewsTrial: Bool {
        Bundle.main.object(forInfoDictionaryKey: "WinMuxWorkspaceViewsTrial") as? Bool ?? false
    }
    public static var defaultRoot: URL {
        root(forViewsTrial: isViewsTrial)
    }
    static func root(forViewsTrial trial: Bool, applicationSupport: URL =
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)) -> URL {
        guard trial else { return applicationSupport.appendingPathComponent("WinMux Browser Workspace Alpha", isDirectory: true) }
        let legacy = applicationSupport.appendingPathComponent("WinMux Browser Views Trial", isDirectory: true)
        // Earlier builds also used this directory for an unmanaged Chromium
        // profile. Keep actual workspace state; never adopt or delete that
        // unmarked browser directory, or relax the store's ownership checks.
        if ["workspace-activation-v1", "request.json", "status.json"].contains(where: {
            FileManager.default.fileExists(atPath: legacy.appendingPathComponent($0).path)
        }) { return legacy }
        return applicationSupport.appendingPathComponent("WinMux Browser Views Trial Workspace", isDirectory: true)
    }
    public init(root: URL = Self.defaultRoot) throws {
        guard root.isFileURL, root.path.hasPrefix("/"),
              root.standardizedFileURL.resolvingSymlinksInPath().path == root.standardizedFileURL.path else {
            throw WorkspaceActivationError.unsafeDirectory
        }
        self.root = root.standardizedFileURL
    }

    private func check(_ url: URL) throws {
        guard url.resolvingSymlinksInPath().path == url.path else { throw WorkspaceActivationError.unsafeDirectory }
        if FileManager.default.fileExists(atPath: url.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 else {
                throw WorkspaceActivationError.unsafeDirectory
            }
        }
    }

    public func prepare() throws {
        let fm = FileManager.default, marker = root.appendingPathComponent("workspace-activation-v1")
        try check(root); try check(marker)
        if fm.fileExists(atPath: root.path) {
            guard (try? String(contentsOf: marker, encoding: .utf8)) == "winmux-workspace-activation\n" else {
                throw WorkspaceActivationError.unsafeDirectory
            }
        } else {
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data("winmux-workspace-activation\n".utf8).write(to: marker, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        }
    }

    public func lock() throws -> WorkspaceActivationLock {
        try prepare()
        return try WorkspaceActivationLock(url: root.appendingPathComponent("activation.lock"))
    }

    public func prepareDirectories(for request: WorkspaceActivation) throws {
        try request.validate(); try prepare()
        let fm = FileManager.default
        // The native state creates its own marker. A profile is only created
        // inside this marked activation root, never from a caller-supplied path.
        for url in [root.appendingPathComponent("validation"), request.directory(in: root), request.profile(in: root)] {
            try check(url)
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try check(request.nativeState(in: root))
    }

    public func readRequest() throws -> WorkspaceActivation? {
        let request: WorkspaceActivation? = try read("request.json")
        try request?.validate()
        return request
    }
    public func writeRequest(_ request: WorkspaceActivation) throws {
        try prepareDirectories(for: request)
        try write(request, name: "request.json")
    }
    public func readStatus() throws -> WorkspaceActivationStatus? { try read("status.json") }
    public func writeStatus(_ status: WorkspaceActivationStatus) throws { try write(status, name: "status.json") }

    private func read<T: Decodable>(_ name: String) throws -> T? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        try prepare()
        let file = root.appendingPathComponent(name)
        try check(file)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        guard data.count <= 16384 else { throw WorkspaceActivationError.invalidRequest }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func write<T: Encodable>(_ value: T, name: String) throws {
        try prepare()
        let file = root.appendingPathComponent(name)
        try check(file)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
