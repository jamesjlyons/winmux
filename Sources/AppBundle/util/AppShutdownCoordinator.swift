import AppKit
import Common

@MainActor
final class AppShutdownCoordinator {
    static let shared = AppShutdownCoordinator()
    private(set) var isShuttingDown = false
    private var shutdownTask: Task<Void, Never>?

    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        // Capture now, then wait for the serialized writer before moving windows for cleanup.
        let finalSave = persistFrozenWorldForRestartIfPossible()
        isShuttingDown = true
        TrackpadNavigationController.shared.shutdown()
        let task = Task { @MainActor in
            await finalSave?.value
            guard isWinMuxRuntimeReady else { return }
            await runBoundedShutdown(timeout: .seconds(5)) {
                try? await makeAllWindowsVisibleAndRestoreSize()
                await toggleReleaseServerIfDebug(.on)
            }
        }
        shutdownTask = task
        await task.value
    }
}

@MainActor
func runBoundedShutdown(timeout: Duration, cleanup: @escaping @MainActor () async -> Void) async {
    await withCheckedContinuation { continuation in
        let completion = ShutdownCompletion(continuation)
        completion.cleanup = Task { @MainActor in
            await cleanup()
            completion.finish()
        }
        completion.timeout = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            completion.finish()
        }
    }
}

@MainActor
private final class ShutdownCompletion {
    var cleanup: Task<Void, Never>?
    var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func finish() {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        cleanup?.cancel()
        timeout = nil
        cleanup = nil
        continuation.resume()
    }
}

@MainActor
public final class WinMuxApplicationDelegate: NSObject, NSApplicationDelegate {
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppShutdownCoordinator.shared.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
