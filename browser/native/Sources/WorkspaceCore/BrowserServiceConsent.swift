import Foundation

/// Bootstrap consent is read before Chromium constructs network services.
/// Browser profile preferences remain engine-owned; this file only gates services.
public struct BrowserServiceConsent: Codable, Equatable, Sendable {
    public var version = 1
    public var securityUpdates = false
    public var extensionUpdates = false
    public var filterUpdates = false
    public init() {}
    enum CodingKeys: String, CodingKey {
        case version
        case securityUpdates = "security_updates", extensionUpdates = "extension_updates", filterUpdates = "filter_updates"
    }
    public static func read(profile: URL) -> Self {
        guard let data = try? Data(contentsOf: profile.appendingPathComponent("winmux-services.json")), data.count <= 8192,
              let consent = try? JSONDecoder().decode(Self.self, from: data), consent.version == 1 else { return .init() }
        return consent
    }
    public func write(profile: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = profile.appendingPathComponent("winmux-services.json")
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
