import Foundation

/// A bounded query result from Chromium's existing profile history. The helper
/// never persists a second copy of browsing history.
public struct BrowserHistoryEntry: Codable, Equatable, Sendable {
    public let url: String
    public let title: String
    public let visitCount: Int
    public let lastVisit: Double

    public init(url: String, title: String, visitCount: Int = 0, lastVisit: Double = 0) {
        self.url = url; self.title = title; self.visitCount = visitCount; self.lastVisit = lastVisit
    }

    enum CodingKeys: String, CodingKey {
        case url, title, visitCount = "visit_count", lastVisit = "last_visit"
    }

    public var isValid: Bool {
        guard url.utf8.count <= 8192, title.utf8.count <= 4096, visitCount >= 0, lastVisit.isFinite,
              let components = URLComponents(string: url),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false, components.user == nil, components.password == nil else { return false }
        return true
    }
}

public struct BrowserHistoryRequest: Sendable {
    public let epoch: UUID
    public let surfaceID: SurfaceID
    public let query: String
}
