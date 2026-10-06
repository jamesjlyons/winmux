/// A normal app launch or Start records an intent, consumed once after
/// Accessibility is granted. Inspecting setup alone does not create an intent.
public struct WorkspaceSetupStartIntent {
    public private(set) var awaitingAccessibility = false
    public init() {}

    public mutating func request(accessibilityGranted: Bool) -> Bool {
        awaitingAccessibility = !accessibilityGranted
        return accessibilityGranted
    }

    public mutating func consumePermissionGrant(accessibilityGranted: Bool) -> Bool {
        guard awaitingAccessibility, accessibilityGranted else { return false }
        awaitingAccessibility = false
        return true
    }

    public mutating func cancel() { awaitingAccessibility = false }
}
