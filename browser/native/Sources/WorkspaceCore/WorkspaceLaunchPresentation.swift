/// Launch stays invisible unless the user must grant permission or resolve a
/// failure. The full setup window is an explicit diagnostic action only.
public enum WorkspaceLaunchPresentation: Equatable {
    case hidden, accessibility, backgroundApproval, failure, setup

    public static func resolve(showSetup: Bool, failed: Bool, needsAccessibility: Bool,
                               needsBackgroundApproval: Bool) -> Self {
        if showSetup { return .setup }
        if failed { return .failure }
        if needsAccessibility { return .accessibility }
        if needsBackgroundApproval { return .backgroundApproval }
        return .hidden
    }
}

/// A dead registration from this package can be restarted once. A live helper,
/// another package, and permission approval must never be displaced by launch.
public func workspaceShouldRecoverLaunch(automaticLaunch: Bool, ownsEnabledService: Bool,
                                         helperAlive: Bool, phase: String?, alreadyRetried: Bool) -> Bool {
    automaticLaunch && ownsEnabledService && !helperAlive && !alreadyRetried &&
        ["ready", "failed", "stopped"].contains(phase ?? "")
}
