import Foundation

public struct BrowserTabRecord: Codable, Equatable, Sendable {
    public let surfaceID: SurfaceID
    public let hostID: String
    public let title: String
    public let selected: Bool
    public let privateBrowsing: Bool
    public let hostWindowID: UInt32?

    public init(surfaceID: SurfaceID, hostID: String, title: String, selected: Bool, privateBrowsing: Bool = false, hostWindowID: UInt32? = nil) {
        self.surfaceID = surfaceID
        self.hostID = hostID
        self.title = title
        self.selected = selected
        self.privateBrowsing = privateBrowsing
        self.hostWindowID = hostWindowID
    }

    enum CodingKeys: String, CodingKey {
        case surfaceID = "surface_id", hostID = "host_id", title, selected
        case privateBrowsing = "private"
        case hostWindowID = "host_window_id"
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
              message.tabs.allSatisfy({ !$0.privateBrowsing && !$0.hostID.isEmpty && $0.hostID.utf8.count <= 128 && $0.title.utf8.count <= 4096 })
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
