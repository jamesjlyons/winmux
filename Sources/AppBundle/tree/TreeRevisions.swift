import Foundation

/// Revisions propagate up the native tree at the mutation, rather than finding
/// changes by freezing or walking every descendant during each interaction.
struct TreeChange: OptionSet, Sendable {
    let rawValue: UInt8
    static let structure = Self(rawValue: 1 << 0)
    static let selection = Self(rawValue: 1 << 1)
    static let geometry = Self(rawValue: 1 << 2)
    static let metadata = Self(rawValue: 1 << 3)
    static let persistence = Self(rawValue: 1 << 4)
    /// Applied frame output affects chrome, but must not dirty layout input.
    static let presentation = Self(rawValue: 1 << 5)
}

struct TreeRevisions: Equatable, Sendable {
    private(set) var structure: UInt64 = 0
    private(set) var selection: UInt64 = 0
    private(set) var geometry: UInt64 = 0
    private(set) var metadata: UInt64 = 0
    private(set) var persistence: UInt64 = 0
    private(set) var presentation: UInt64 = 0

    mutating func record(_ change: TreeChange) {
        if change.contains(.structure) { structure &+= 1 }
        if change.contains(.selection) { selection &+= 1 }
        if change.contains(.geometry) { geometry &+= 1 }
        if change.contains(.metadata) { metadata &+= 1 }
        if change.contains(.persistence) { persistence &+= 1 }
        if change.contains(.presentation) { presentation &+= 1 }
    }
}
