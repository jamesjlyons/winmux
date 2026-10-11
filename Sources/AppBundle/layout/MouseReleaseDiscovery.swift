import AppKit

/// A click identifies the app whose unreliable creation/destruction events we
/// need to recover. Unknown targets retain bounded global recovery.
@MainActor
final class MouseReleaseDiscovery {
    static let shared = MouseReleaseDiscovery()
    private var targetPID: pid_t?
    private var recovery: Task<Void, Never>?
    private var lastRecovery: TimeInterval = -.infinity
    private let now: () -> TimeInterval
    private let discover: (WindowRefreshScope) -> Void

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         discover: @escaping (WindowRefreshScope) -> Void = {
             scheduleRefreshSession(.globalObserverLeftMouseUp, scope: $0)
         }) {
        self.now = now
        self.discover = discover
    }

    func mouseDown(targetPID: pid_t?) { self.targetPID = targetPID }

    func mouseUp(dragOwner: pid_t? = nil) {
        let pids = Set([targetPID, dragOwner].compactMap { $0 }.filter { $0 > 0 })
        targetPID = nil
        if !pids.isEmpty { discover(.apps(pids)); return }
        guard recovery == nil else { return }
        let delay = max(0.25, lastRecovery + 1 - now())
        recovery = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.recovery = nil
            self.lastRecovery = self.now()
            self.discover(.all)
        }
    }

    func cancel() { recovery?.cancel(); recovery = nil; targetPID = nil }
    func waitForRecoveryForTests() async { await recovery?.value }
}

/// At most one hover update per display delivery; buttons always flush the
/// latest position first and run synchronously, preserving release ordering.
@MainActor
final class PointerActivityCoalescer {
    static let shared = PointerActivityCoalescer()
    private var pending: (() -> Void)?

    func submit(_ action: @escaping () -> Void) {
        let wasPending = pending != nil
        pending = action
        if !wasPending {
            DisplayRefreshDriver.shared.add(owner: self) { [weak self] _ in self?.flush() }
        }
    }

    func cancel() {
        pending = nil
        DisplayRefreshDriver.shared.remove(owner: self)
    }

    func flush() {
        guard let action = pending else { return }
        pending = nil
        DisplayRefreshDriver.shared.remove(owner: self)
        action()
    }
}
