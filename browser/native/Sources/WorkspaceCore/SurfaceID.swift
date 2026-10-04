import Foundation

/// Workspace identity is independent of a renderer, tab index, PID or CGWindowID.
/// Browser ownership includes the profile so moving a tab never changes its account.
public enum SurfaceID: Hashable, Sendable, Codable, CustomStringConvertible {
    case nativeWindow(UUID)
    case browserTab(profile: UUID, tab: UUID)

    public var description: String {
        switch self {
        case .nativeWindow(let id): "native:\(id.uuidString.lowercased())"
        case .browserTab(let profile, let tab): "browser:\(profile.uuidString.lowercased()):\(tab.uuidString.lowercased())"
        }
    }

    public init?(string: String) {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, parts[0] == "native", let id = UUID(uuidString: String(parts[1])) {
            self = .nativeWindow(id)
        } else if parts.count == 3, parts[0] == "browser",
                  let profile = UUID(uuidString: String(parts[1])), let tab = UUID(uuidString: String(parts[2])) {
            self = .browserTab(profile: profile, tab: tab)
        } else { return nil }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let id = Self(string: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid typed surface identity")
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct SurfaceCapabilities: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let focus = Self(rawValue: 1 << 0)
    public static let close = Self(rawValue: 1 << 1)
    public static let move = Self(rawValue: 1 << 2)
    public static let resize = Self(rawValue: 1 << 3)
    public static let navigate = Self(rawValue: 1 << 4)
    public static let reload = Self(rawValue: 1 << 5)
    public static let duplicate = Self(rawValue: 1 << 6)
    public static let mute = Self(rawValue: 1 << 7)
    public static let nativeWindow: Self = [.focus, .close, .move, .resize]
    public static let browserTab: Self = [.focus, .close, .move, .resize, .navigate, .reload, .duplicate, .mute]
}

/// Issued means handed to the owning adapter, not confirmed focus/input readiness
/// or completed closure. Owners report lifecycle completion separately.
public enum SurfaceActionOutcome: Equatable, Sendable {
    case issued
    case unavailable
    case unsupported
}

@MainActor
public protocol SurfaceAdapter {
    var surfaceID: SurfaceID { get }
    var capabilities: SurfaceCapabilities { get }
    func requestFocus() -> SurfaceActionOutcome
    func requestClose() -> SurfaceActionOutcome
}
