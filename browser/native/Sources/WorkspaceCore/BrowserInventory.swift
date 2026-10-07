import Foundation

public struct BrowserPinnedExtension: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let iconPNGBase64: String?
    public let isEnabled: Bool
    public let canUnpin: Bool

    public init(id: String, title: String, iconPNGBase64: String? = nil, isEnabled: Bool = true, canUnpin: Bool = true) {
        self.id = id; self.title = title; self.iconPNGBase64 = iconPNGBase64
        self.isEnabled = isEnabled; self.canUnpin = canUnpin
    }
    enum CodingKeys: String, CodingKey {
        case id, title, iconPNGBase64 = "icon_png_base64", isEnabled = "enabled", canUnpin = "can_unpin"
    }
    public var isValid: Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (97...112).contains($0) } &&
            title.utf8.count <= 4096 && (iconPNGBase64?.utf8.count ?? 0) <= 16384
    }
}

public struct BrowserTabRecord: Codable, Equatable, Sendable {
    public var pinnedExtensions: [BrowserPinnedExtension] = []
    public var activeDownloads: Int = 0
    public let lifecycle: BrowserPageLifecycle
    public let keepActive: Bool
    public let blockingEnabled: Bool
    public let blockedRequests: Int
    public let privacy: BrowserPrivacySettings?
    public let surfaceID: SurfaceID
    public let hostID: String
    public let title: String
    public let selected: Bool
    public let url: String
    public let iconPNGBase64: String?
    public let canGoBack: Bool
    public let canGoForward: Bool
    public let isLoading: Bool
    public let hostManaged: Bool
    public let hostMinimized: Bool
    public let hostFullscreen: Bool
    public let hostZoomed: Bool
    public let focused: Bool
    public let privateBrowsing: Bool
    public let hostWindowID: UInt32?
    public let hostFrame: SurfaceFrame?
    public let hostVisible: Bool?
    public let hostMinimumSize: SurfaceMinimumSize?
    /// Owner-confirmed initial profile; UUIDs alone cannot identify Shared.
    public var isSharedProfile: Bool? = nil

    public init(surfaceID: SurfaceID, hostID: String, title: String, selected: Bool, privateBrowsing: Bool = false, hostWindowID: UInt32? = nil, hostFrame: SurfaceFrame? = nil, hostVisible: Bool? = nil, hostMinimumSize: SurfaceMinimumSize? = nil, url: String = "", canGoBack: Bool = false, canGoForward: Bool = false, isLoading: Bool = false, hostManaged: Bool = false, hostMinimized: Bool = false, hostFullscreen: Bool = false, hostZoomed: Bool = false, focused: Bool = false, iconPNGBase64: String? = nil, lifecycle: BrowserPageLifecycle = .active, keepActive: Bool = false, blockingEnabled: Bool = true, blockedRequests: Int = 0, privacy: BrowserPrivacySettings? = nil) {
        self.lifecycle = lifecycle; self.keepActive = keepActive; self.blockingEnabled = blockingEnabled; self.blockedRequests = max(0, blockedRequests); self.privacy = privacy
        self.surfaceID = surfaceID
        self.hostID = hostID
        self.title = title
        self.selected = selected
        self.url = url
        self.iconPNGBase64 = iconPNGBase64
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        self.hostManaged = hostManaged
        self.hostMinimized = hostMinimized
        self.hostFullscreen = hostFullscreen
        self.hostZoomed = hostZoomed
        self.focused = focused
        self.privateBrowsing = privateBrowsing
        self.hostWindowID = hostWindowID
        self.hostFrame = hostFrame; self.hostVisible = hostVisible
        self.hostMinimumSize = hostMinimumSize
    }

    enum CodingKeys: String, CodingKey {
        case pinnedExtensions = "pinned_extensions", activeDownloads = "active_downloads"
        case lifecycle, keepActive = "keep_active", blockingEnabled = "blocking_enabled", privacy
        case blockedRequests = "blocked_requests"
        case surfaceID = "surface_id", hostID = "host_id", title, selected
        case privateBrowsing = "private"
        case hostWindowID = "host_window_id"
        case hostFrame = "host_frame", hostVisible = "host_visible"
        case hostMinimumSize = "host_minimum_size"
        case iconPNGBase64 = "icon_png_base64"
        case isSharedProfile = "is_shared_profile"
        case url, canGoBack = "can_go_back", canGoForward = "can_go_forward"
        case isLoading = "is_loading", hostManaged = "host_managed", focused
        case hostMinimized = "host_minimized", hostFullscreen = "host_fullscreen", hostZoomed = "host_zoomed"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(surfaceID: try values.decode(SurfaceID.self, forKey: .surfaceID),
                  hostID: try values.decode(String.self, forKey: .hostID),
                  title: try values.decode(String.self, forKey: .title),
                  selected: try values.decode(Bool.self, forKey: .selected),
                  privateBrowsing: try values.decode(Bool.self, forKey: .privateBrowsing),
                  hostWindowID: try values.decodeIfPresent(UInt32.self, forKey: .hostWindowID),
                  hostFrame: try values.decodeIfPresent(SurfaceFrame.self, forKey: .hostFrame),
                  hostVisible: try values.decodeIfPresent(Bool.self, forKey: .hostVisible),
                  hostMinimumSize: try values.decodeIfPresent(SurfaceMinimumSize.self, forKey: .hostMinimumSize),
                  url: try values.decodeIfPresent(String.self, forKey: .url) ?? "",
                  canGoBack: try values.decodeIfPresent(Bool.self, forKey: .canGoBack) ?? false,
                  canGoForward: try values.decodeIfPresent(Bool.self, forKey: .canGoForward) ?? false,
                  isLoading: try values.decodeIfPresent(Bool.self, forKey: .isLoading) ?? false,
                  hostManaged: try values.decodeIfPresent(Bool.self, forKey: .hostManaged) ?? false,
                  hostMinimized: try values.decodeIfPresent(Bool.self, forKey: .hostMinimized) ?? false,
                  hostFullscreen: try values.decodeIfPresent(Bool.self, forKey: .hostFullscreen) ?? false,
                  hostZoomed: try values.decodeIfPresent(Bool.self, forKey: .hostZoomed) ?? false,
                  focused: try values.decodeIfPresent(Bool.self, forKey: .focused) ?? false,
                  iconPNGBase64: try values.decodeIfPresent(String.self, forKey: .iconPNGBase64),
                  lifecycle: try values.decodeIfPresent(BrowserPageLifecycle.self, forKey: .lifecycle) ?? .active,
                  keepActive: try values.decodeIfPresent(Bool.self, forKey: .keepActive) ?? false,
                  blockingEnabled: try values.decodeIfPresent(Bool.self, forKey: .blockingEnabled) ?? true,
                  blockedRequests: try values.decodeIfPresent(Int.self, forKey: .blockedRequests) ?? 0,
                  privacy: try values.decodeIfPresent(BrowserPrivacySettings.self, forKey: .privacy))
        pinnedExtensions = try values.decodeIfPresent([BrowserPinnedExtension].self, forKey: .pinnedExtensions) ?? []
        activeDownloads = try values.decodeIfPresent(Int.self, forKey: .activeDownloads) ?? 0
        isSharedProfile = try values.decodeIfPresent(Bool.self, forKey: .isSharedProfile)
    }
}

public struct BrowserInventoryMessage: Codable, Sendable {
    public let revision: UInt64
    public let full: Bool
    public let tabs: [BrowserTabRecord]
    public let removed: [SurfaceID]

    public init(revision: UInt64, full: Bool, tabs: [BrowserTabRecord], removed: [SurfaceID] = []) {
        self.revision = revision
        self.full = full
        self.tabs = tabs
        self.removed = removed
    }
}

/// Connection-scoped mirror of browser-owned state. The authenticated endpoint
/// owns synchronization and discards this value when its connection ends.
/// This is deliberately not Codable: browser metadata is not a workspace file.
public struct BrowserInventory: Sendable {
    public private(set) var revision: UInt64 = 0
    public private(set) var tabs: [SurfaceID: BrowserTabRecord] = [:]
    public init() {}

    @discardableResult
    public mutating func apply(_ message: BrowserInventoryMessage) -> Bool {
        guard message.revision > revision, revision != 0 || message.full,
              message.full || message.revision == revision + 1,
              message.tabs.count <= 10_000, message.removed.count <= 10_000,
              !message.full || message.removed.isEmpty else { return false }
        guard message.tabs.allSatisfy({ record in
            record.pinnedExtensions.count <= 32 && record.pinnedExtensions.allSatisfy(\.isValid) &&
                Set(record.pinnedExtensions.map(\.id)).count == record.pinnedExtensions.count &&
                (0...100_000).contains(record.activeDownloads)
        }) else { return false }
        let changed = message.tabs.map(\.surfaceID)
        guard Set(changed).count == changed.count,
              Set(message.removed).count == message.removed.count,
              Set(changed).isDisjoint(with: message.removed),
              (changed + message.removed).allSatisfy({ if case .browserTab = $0 { return true }; return false }),
              message.tabs.allSatisfy({ !$0.hostID.isEmpty && $0.hostID.utf8.count <= 128 && $0.title.utf8.count <= 4096 && $0.url.utf8.count <= 16_384 && ($0.iconPNGBase64?.utf8.count ?? 0) <= 131072 && ($0.hostMinimumSize?.isValid ?? true) })
        else { return false }
        guard message.tabs.allSatisfy({ record in
            tabs[record.surfaceID].map { $0.privateBrowsing == record.privateBrowsing } ?? true
        }) else { return false }
        var next = message.full ? [:] : tabs
        for id in message.removed {
            guard next.removeValue(forKey: id) != nil else { return false }
        }
        for tab in message.tabs { next[tab.surfaceID] = tab }
        guard next.count <= 10_000 else { return false }
        var hosts: [String: UInt32] = [:]
        var windows: [UInt32: String] = [:]
        var privateProfiles: [UUID: Bool] = [:]
        for tab in next.values {
            if case .browserTab(let profile, _) = tab.surfaceID {
                guard privateProfiles[profile].map({ $0 == tab.privateBrowsing }) ?? true else { return false }
                privateProfiles[profile] = tab.privateBrowsing
            }
            if let window = tab.hostWindowID {
                guard window > 0, hosts[tab.hostID] == nil || hosts[tab.hostID] == window,
                      windows[window] == nil || windows[window] == tab.hostID else { return false }
                hosts[tab.hostID] = window
                windows[window] = tab.hostID
            }
        }
        tabs = next
        revision = message.revision
        return true
    }
}
