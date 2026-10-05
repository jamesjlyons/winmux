import Foundation

/// A named Chromium profile owned by this workspace installation. The UUID,
/// never a display name or Space name, identifies its persistent browser data.
public struct WorkspaceBrowserProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    // The owner bounds profile identity lookup to 64 registered profiles;
    // reserve one for the shared initial profile.
    public static let maximumCount = 63
    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isValid: Bool {
        !name.isEmpty && name.utf8.count <= 128 &&
            name == name.trimmingCharacters(in: .whitespacesAndNewlines) &&
            !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// Nil on BrowserNewTabRequest retains the explicit page/pin profile route.
/// Shared always targets Chromium's initial profile, not its last-used account.
public enum WorkspaceBrowserProfileTarget: Equatable, Sendable {
    case shared
    case named(WorkspaceBrowserProfile)

    public var key: String {
        switch self { case .shared: "shared"; case .named(let profile): profile.id.uuidString.lowercased() }
    }
    public var name: String {
        switch self { case .shared: "Shared"; case .named(let profile): profile.name }
    }
    public var profileID: UUID? {
        switch self { case .shared: nil; case .named(let profile): profile.id }
    }
    public var isValid: Bool {
        switch self { case .shared: true; case .named(let profile): profile.isValid }
    }
}
