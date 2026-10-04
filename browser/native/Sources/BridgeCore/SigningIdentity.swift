import Foundation
import Security

public enum SigningIdentity {
    public static let browserID = "com.jameslyons.winmux.browser.alpha"
    public static let helperID = "com.jameslyons.winmux.browser.alpha.workspace"
    public static let serviceName = helperID

    /// Derive the team from the running signed code, never from an IPC payload,
    /// a PID lookup, or an environment variable supplied by a connecting client.
    public static func ownTeamID() throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                           &information) == errSecSuccess,
              let info = information as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              isTeamID(team) else {
            throw NSError(domain: "WinMuxBrowser.Signing", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "A stable Apple signing identity is required."])
        }
        return team
    }

    public static func requirement(identifier: String, teamID: String) -> String? {
        guard [browserID, helperID].contains(identifier), isTeamID(teamID) else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    private static func isTeamID(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }
}
