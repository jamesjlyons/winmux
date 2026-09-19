import Foundation
import ServiceManagement

/// Called by the signed foreground browser, never by a renderer or website.
/// Registration is deliberately explicit; a transport test must not enroll a
/// background service or take ownership of the user's native windows.
public enum HelperRegistration {
    public static let plistName = SigningIdentity.serviceName + ".plist"

    public static var status: SMAppService.Status {
        SMAppService.agent(plistName: plistName).status
    }

    public static func register() throws {
        try SMAppService.agent(plistName: plistName).register()
    }

    public static func unregister() async throws {
        try await SMAppService.agent(plistName: plistName).unregister()
    }
}
