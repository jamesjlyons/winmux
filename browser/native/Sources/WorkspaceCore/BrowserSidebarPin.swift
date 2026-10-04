import Foundation

/// A page explicitly saved by the user. Live membership remains browser-owned;
/// a missing surface is a shortcut and never creates a page during restoration.
public struct BrowserSidebarPin: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let profileID: UUID
    public var workspaceName: String
    public let title: String
    public let url: String
    public var surfaceID: SurfaceID?
    public var iconPNGBase64: String?

    public init(id: UUID = UUID(), profileID: UUID, workspaceName: String, title: String, url: String, surfaceID: SurfaceID? = nil, iconPNGBase64: String? = nil) {
        self.id = id; self.profileID = profileID; self.workspaceName = workspaceName
        self.title = title; self.url = url; self.surfaceID = surfaceID; self.iconPNGBase64 = iconPNGBase64
    }

    public var isValid: Bool {
        (iconPNGBase64?.utf8.count ?? 0) <= 131072 && !workspaceName.isEmpty && workspaceName.utf8.count <= 1024 &&
            title.utf8.count <= 4096 && !url.isEmpty && url.utf8.count <= 16_384 &&
            (surfaceID.map { if case .browserTab(let profile, _) = $0 { return profile == profileID }; return false } ?? true)
    }
}
