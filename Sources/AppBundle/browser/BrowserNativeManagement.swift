import AppKit
import Common
import CryptoKit
import Darwin
import WorkspaceCore

/// Alpha activation never imports the standalone app's configuration or session.
struct BrowserNativeState: Sendable {
    let directory: URL
    var config: URL { directory.appendingPathComponent("winmux.toml") }
    var session: URL { directory.appendingPathComponent("window-state.json") }
    var socket: String {
        let hash = SHA256.hash(data: Data(directory.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "/tmp/winmux-browser-\(getuid())-\(hash).sock"
    }

    init(directory: URL, workspaceShortcuts: Bool = false) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/") else { throw NativeManagementError.invalidState }
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        let marker = self.directory.appendingPathComponent("winmux-browser-state-v1")
        if fm.fileExists(atPath: self.directory.path) {
            guard (try? String(contentsOf: marker, encoding: .utf8)) == "isolated-browser-workspace\n" else {
                throw NativeManagementError.invalidState
            }
        } else {
            try fm.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data("isolated-browser-workspace\n".utf8).write(to: marker, options: .withoutOverwriting)
        }
        for file in [config, session, session.appendingPathExtension("backup"), marker] {
            guard file.resolvingSymlinksInPath().path == file.path else { throw NativeManagementError.invalidState }
        }
        if !fm.fileExists(atPath: config.path) {
            let shortcuts = workspaceShortcuts ? "\nalt-j = 'focus tab-next'\nalt-k = 'focus tab-prev'\nalt-space = 'layout horizontal vertical'\n" : ""
            try Data((Self.initialConfiguration + shortcuts).utf8).write(to: config, options: .withoutOverwriting)
        }
    }

    static let initialConfiguration = """
    config-version = 2
    start-at-login = false
    auto-reload-config = true
    persistent-workspaces = []
    shortcuts-preset = 'none'
    automatically-unhide-macos-hidden-apps = false
    [workspace-sidebar]
    enabled = true
    always-expanded = false
    chrome-style = 'solid'
    solid-chrome-color = 'system'
    [mode.main.binding]
    """
}

enum NativeManagementError: LocalizedError {
    case invalidState, anotherManager, invalidProcess, lockUnavailable, invalidConfiguration
    var errorDescription: String? {
        switch self {
            case .invalidState: "Native activation requires a new directory or an existing isolated WinMux Browser state directory."
            case .anotherManager: "Another WinMux owns native windows. Quit that manager before activating the browser workspace."
            case .invalidProcess: "The explicitly scoped native process is no longer running."
            case .lockUnavailable: "Could not acquire exclusive native workspace ownership."
            case .invalidConfiguration: "The isolated browser workspace configuration could not be loaded."
        }
    }
}

/// A process-lifetime lease; never unlink a flock file (that would split owners).
final class NativeManagementLease: @unchecked Sendable {
    private let descriptor: Int32
    private let mutex = NSLock()
    private var revoked = false
    var isRevoked: Bool { mutex.withLock { revoked } }
    func revoke() { mutex.withLock { revoked = true } }

    init(path: String = "/tmp/com.jameslyons.winmux.native-management-\(getuid()).lock") throws {
        descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NativeManagementError.lockUnavailable }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw NativeManagementError.lockUnavailable
        }
    }
    deinit { Darwin.close(descriptor) }
}

@MainActor
enum BrowserNativeManagement {
    static var lease: NativeManagementLease?
    static var processScope: (pid: Int32, launch: Date)?
    private static var ownershipObserver: NSObjectProtocol?

    static func isStandaloneManager(bundleID: String?, executable: String?) -> Bool {
        [stableWinMuxAppId, stableWinMuxAppId + ".debug"].contains(bundleID ?? "") ||
            ["WinMux", "WinMux-Debug", "WinMuxApp"].contains(executable ?? "")
    }

    static func checkOwnership() throws {
        guard !NSWorkspace.shared.runningApplications.contains(where: {
            $0.processIdentifier != myPid && !$0.isTerminated &&
                isStandaloneManager(bundleID: $0.bundleIdentifier, executable: $0.executableURL?.lastPathComponent)
        }) else { throw NativeManagementError.anotherManager }
    }

    static func allowsDiscovery(_ app: NSRunningApplication) -> Bool {
        guard let scope = processScope else { return true }
        return app.processIdentifier == scope.pid && processLaunchDate(scope.pid) == scope.launch && !app.isTerminated
    }

    static func observeOwnership() {
        ownershipObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard (try? checkOwnership()) == nil else { return }
                // Stop writes before yielding the run loop, and do not restore
                // windows over the newly launched standalone manager on exit.
                lease?.revoke()
                resetHotKeys()
                TrackpadNavigationController.shared.shutdown()
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

/// Explicit only. Normal helper enrollment remains transport-only. An optional
/// launch-bound PID scope permits live integration tests using only fixture windows.
@MainActor
public func checkBrowserNativeOwnership() throws { try BrowserNativeManagement.checkOwnership() }

@MainActor
public func startBrowserNativeManagement(stateDirectory: URL, nativeProcessID: Int32? = nil,
                                         expectedProcessLaunch: Date? = nil, workspaceShortcuts: Bool = false) async throws {
    guard BrowserNativeManagement.lease == nil, !isWinMuxRuntimeReady else { throw NativeManagementError.anotherManager }
    try BrowserNativeManagement.checkOwnership()
    let lease = try NativeManagementLease()
    if let pid = nativeProcessID {
        guard pid != myPid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              let launch = processLaunchDate(pid), expectedProcessLaunch == nil || launch == expectedProcessLaunch else {
            throw NativeManagementError.invalidProcess
        }
        BrowserNativeManagement.processScope = (pid, launch)
    }
    let state = try BrowserNativeState(directory: stateDirectory, workspaceShortcuts: workspaceShortcuts)
    configureBrowserNativeState(state, lease: lease)
    BrowserNativeManagement.lease = lease
    BrowserNativeManagement.observeOwnership()
    try await initializeAppBundle(isolatedBrowser: true)
}
