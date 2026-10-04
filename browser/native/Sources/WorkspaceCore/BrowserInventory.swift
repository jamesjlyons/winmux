import Foundation

public struct BrowserTabRecord: Codable, Equatable, Sendable {
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

    public init(surfaceID: SurfaceID, hostID: String, title: String, selected: Bool, privateBrowsing: Bool = false, hostWindowID: UInt32? = nil, hostFrame: SurfaceFrame? = nil, hostVisible: Bool? = nil, hostMinimumSize: SurfaceMinimumSize? = nil, url: String = "", canGoBack: Bool = false, canGoForward: Bool = false, isLoading: Bool = false, hostManaged: Bool = false, hostMinimized: Bool = false, hostFullscreen: Bool = false, hostZoomed: Bool = false, focused: Bool = false, iconPNGBase64: String? = nil) {
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
        case surfaceID = "surface_id", hostID = "host_id", title, selected
        case privateBrowsing = "private"
        case hostWindowID = "host_window_id"
        case hostFrame = "host_frame", hostVisible = "host_visible"
        case hostMinimumSize = "host_minimum_size"
        case iconPNGBase64 = "icon_png_base64"
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
                  iconPNGBase64: try values.decodeIfPresent(String.self, forKey: .iconPNGBase64))
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
        let changed = message.tabs.map(\.surfaceID)
        guard Set(changed).count == changed.count,
              Set(message.removed).count == message.removed.count,
              Set(changed).isDisjoint(with: message.removed),
              (changed + message.removed).allSatisfy({ if case .browserTab = $0 { return true }; return false }),
              message.tabs.allSatisfy({ !$0.privateBrowsing && !$0.hostID.isEmpty && $0.hostID.utf8.count <= 128 && $0.title.utf8.count <= 4096 && $0.url.utf8.count <= 16_384 && ($0.iconPNGBase64?.utf8.count ?? 0) <= 131072 && ($0.hostMinimumSize?.isValid ?? true) })
        else { return false }
        var next = message.full ? [:] : tabs
        for id in message.removed {
            guard next.removeValue(forKey: id) != nil else { return false }
        }
        for tab in message.tabs { next[tab.surfaceID] = tab }
        guard next.count <= 10_000 else { return false }
        var hosts: [String: UInt32] = [:]
        var windows: [UInt32: String] = [:]
        for tab in next.values {
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
