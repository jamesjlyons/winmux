import AppKit
import Common

/// App-local lifecycle notifications do not need to enumerate unrelated applications.
enum WindowRefreshScope: Equatable, Sendable {
    case all
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
            case .all: true
            case .apps(let pids): pids.contains(pid)
        }
    }

    func union(_ other: Self) -> Self {
        switch (self, other) {
            case (.apps(let lhs), .apps(let rhs)): .apps(lhs.union(rhs))
            default: .all
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
