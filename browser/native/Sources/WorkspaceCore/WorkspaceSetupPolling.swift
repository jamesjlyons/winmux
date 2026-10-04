import Foundation

/// Fast readiness checks are limited to a newly requested automatic launch.
/// Use monotonic uptime so clock adjustments cannot prolong the fast cadence.
public func workspaceSetupRefreshInterval(automaticLaunchStartedAt: TimeInterval?, now: TimeInterval) -> TimeInterval {
    guard let started = automaticLaunchStartedAt,
          now >= started, now - started < 10 else { return 1 }
    return 0.1
}
