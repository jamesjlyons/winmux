import AppKit
import Common

/// App-local lifecycle notifications do not need to enumerate unrelated applications.
enum WindowRefreshScope: Equatable, Sendable {
    case all
    case windows([UInt32: pid_t])
    case apps(Set<pid_t>)

    static func lifecycleNotification(_ notification: String, pid: pid_t?) -> Self {
        guard let pid,
              notification == kAXWindowCreatedNotification as String ||
              notification == kAXUIElementDestroyedNotification as String
        else { return .all }
        return .apps([pid])
    }

    func contains(_ pid: pid_t) -> Bool {
        switch self {
            case .windows(let owners): owners.values.contains(pid)
            case .all: true
            case .apps(let pids): pids.contains(pid)
        }
    }

    var requiresDiscovery: Bool {
        if case .windows = self { return false }
        return true
    }

    @MainActor
    func contains(_ window: Window) -> Bool {
        if case .windows(let owners) = self {
            return owners[window.windowId] == window.app.pid
        }
        return contains(window.app.pid)
    }

    @MainActor
    static func geometry(_ window: Window) -> Self {
        .windows([window.windowId: window.app.pid])
    }

    func union(_ other: Self) -> Self {
        switch (self, other) {
            case (.all, _), (_, .all): .all
            case (.windows(let lhs), .windows(let rhs)): .windows(lhs.merging(rhs) { _, latest in latest })
            case (.apps(let lhs), .apps(let rhs)): .apps(lhs.union(rhs))
            case (.apps(let pids), .windows(let owners)), (.windows(let owners), .apps(let pids)):
                .apps(pids.union(owners.values))
        }
    }
}

/// Focus-only events must not turn a pending app-local discovery into a global barrier.
func mergedWindowRefreshScope(
    _ lhs: WindowRefreshScope, event lhsEvent: RefreshSessionEvent,
    _ rhs: WindowRefreshScope, event rhsEvent: RefreshSessionEvent,
) -> WindowRefreshScope {
    if !lhsEvent.requiresWindowRefreshBarrier { return rhs }
    if !rhsEvent.requiresWindowRefreshBarrier { return lhs }
    return lhs.union(rhs)
}
