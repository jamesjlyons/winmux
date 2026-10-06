#if canImport(AppBundle)
import AppBundle
import AppKit
import BridgeCore
import ServiceManagement
import WorkspaceCore

/// The trial's native workspace follows its authenticated browser processes,
/// including Quit from launchers such as Raycast. Transport-only helpers and
/// validation services keep their existing independent lifetime.
@MainActor
final class ManagedBrowserLifetime {
    private let request: WorkspaceActivation
    private let store: WorkspaceActivationStore
    private var stopTask: Task<Void, Never>?
    private lazy var lifetime = WorkspaceBrowserLifetime { [weak self] in
        guard let self else { return }
        self.stopTask = Task { await self.stopWorkspace() }
    }

    init(request: WorkspaceActivation, store: WorkspaceActivationStore) {
        self.request = request
        self.store = store
    }

    func observeAuthenticatedBrowser(_ pid: Int32) {
        let executable = URL(fileURLWithPath: request.browserPath).appendingPathComponent("Contents/MacOS/Chromium")
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.bundleIdentifier == SigningIdentity.browserID,
              app.executableURL?.standardizedFileURL == executable.standardizedFileURL,
              let launch = processLaunchDate(pid) else { return }
        lifetime.observe(processID: pid, launch: launch)
        // Cover termination between peer validation and installing the source.
        if app.isTerminated || processLaunchDate(pid) != launch {
            lifetime.confirmExit(processID: pid, launch: launch)
        }
    }

    private func stopWorkspace() async {
        // A concurrent setup operation may briefly own the activation lock.
        for attempt in 0..<50 {
            do {
                let lock = try store.lock()
                defer { withExtendedLifetime(lock) {} }
                guard let current = try store.readRequest(), current == request,
                      let state = try store.readStatus(), state.requestID == request.id,
                      state.helperPID == getpid(), state.helperLaunch == processLaunchDate(getpid()) else {
                    throw WorkspaceActivationError.differentPackage
                }
                try store.writeStatus(.init(requestID: request.id, phase: "stopping",
                    helperPID: getpid(), helperLaunch: state.helperLaunch, detail: "The browser quit."))
                let service = SMAppService.agent(plistName: request.machService + ".plist")
                if service.status != .notRegistered && service.status != .notFound {
                    try await service.unregister()
                }
                // AppKit/SIGTERM use the same bounded native-window restoration
                // path. Keep the live helper identity until that path exits.
                NSApp.terminate(nil)
                return
            } catch WorkspaceActivationError.busy where attempt < 49 {
                try? await Task.sleep(for: .milliseconds(100))
            } catch {
                FileHandle.standardError.write(Data("Workspace quit cleanup: \(error.localizedDescription)\n".utf8))
                NSApp.terminate(nil)
                return
            }
        }
    }
}
#endif
