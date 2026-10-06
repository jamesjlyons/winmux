import Foundation

public struct BrowserPrivacySettings: Codable, Equatable, Sendable {
    public var securityUpdates: Bool
    public var extensionUpdates: Bool
    public var filterUpdates: Bool
    public var searchTemplate: String
    public var thirdPartyCookiesBlocked: Bool
    public init(securityUpdates: Bool = false, extensionUpdates: Bool = false, filterUpdates: Bool = false,
                searchTemplate: String = "https://kagi.com/search?q={searchTerms}", thirdPartyCookiesBlocked: Bool = true) {
        self.securityUpdates = securityUpdates; self.extensionUpdates = extensionUpdates; self.filterUpdates = filterUpdates
        self.searchTemplate = searchTemplate; self.thirdPartyCookiesBlocked = thirdPartyCookiesBlocked
    }
    enum CodingKeys: String, CodingKey {
        case securityUpdates = "security_updates", extensionUpdates = "extension_updates", filterUpdates = "filter_updates"
        case searchTemplate = "search_template", thirdPartyCookiesBlocked = "third_party_cookies_blocked"
    }
}

public enum BrowserPageLifecycle: String, Codable, Sendable { case active, background, frozen, discarded }
