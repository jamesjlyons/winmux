import Foundation

/// Tracks process lifetime independently of XPC connections and tab/window
/// counts. Reconnecting or closing the last window must not stop a workspace.
@MainActor
public final class WorkspaceBrowserLifetime {
    private struct Owner {
        let launch: Date
        let source: DispatchSourceProcess
    }
    private var owners: [Int32: Owner] = [:]
    private let onLastExit: @MainActor () -> Void
    public private(set) var hasRequestedStop = false

    public init(onLastExit: @escaping @MainActor () -> Void) {
        self.onLastExit = onLastExit
    }

    /// Call only after authenticating the browser and verifying its package.
    @discardableResult
    public func observe(processID: Int32, launch: Date) -> Bool {
        guard processID > 0, !hasRequestedStop else { return false }
        if owners[processID]?.launch == launch { return false }
        owners.removeValue(forKey: processID)?.source.cancel()
        let source = DispatchSource.makeProcessSource(identifier: processID, eventMask: .exit, queue: .main)
        owners[processID] = Owner(launch: launch, source: source)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.confirmExit(processID: processID, launch: launch) }
        }
        source.activate()
        return true
    }

    /// Also permits the caller to report a verified exit during observation setup.
    public func confirmExit(processID: Int32, launch: Date) {
        guard owners[processID]?.launch == launch, !hasRequestedStop else { return }
        owners.removeValue(forKey: processID)?.source.cancel()
        guard owners.isEmpty else { return }
        hasRequestedStop = true
        onLastExit()
    }

    isolated deinit { for owner in owners.values { owner.source.cancel() } }
}
