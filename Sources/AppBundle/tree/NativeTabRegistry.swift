import Foundation

/// Process-local native tab identity. Window numbers describe selected AppKit
/// windows; the group owns the durable WinMux surface and placement.
struct NativeTabGroupSnapshot: Equatable, Sendable {
    let id: UUID
    var selectedWindowID: UInt32
    var memberWindowIDs: Set<UInt32>
    var titles: [String]
    var count: Int { titles.count }
}

struct NativeTabRegistry: Sendable {
    private(set) var standaloneWindowIDs: Set<UInt32> = []
    private(set) var groups: [UUID: NativeTabGroupSnapshot] = [:]

    /// Only positive observations change membership. An absent window or a
    /// failed AX read is neither a detach nor a close.
    mutating func observe(group id: UUID, selected: UInt32, titles: [String]) {
        standaloneWindowIDs.remove(selected)
        removeMember(selected, except: id)
        var group = groups[id] ?? .init(id: id, selectedWindowID: selected, memberWindowIDs: [], titles: titles)
        group.selectedWindowID = selected
        group.memberWindowIDs.insert(selected)
        group.titles = titles
        groups[id] = group
    }

    mutating func observeStandalone(_ windowID: UInt32) {
        standaloneWindowIDs.insert(windowID)
        // Keep the last remaining member's identity when AppKit removes the
        // tab bar after a close. It still represents the same physical window.
        for id in Array(groups.keys) {
            guard var group = groups[id], group.memberWindowIDs.contains(windowID) else { continue }
            if group.selectedWindowID == windowID || !group.memberWindowIDs.contains(group.selectedWindowID) {
                group.selectedWindowID = windowID
                group.memberWindowIDs = [windowID]
                group.titles = []
                groups[id] = group
            } else {
                group.memberWindowIDs.remove(windowID)
                groups[id] = group
            }
        }
    }

    mutating func retainAlive(_ alive: Set<UInt32>) {
        standaloneWindowIDs.formIntersection(alive)
        for id in Array(groups.keys) {
            guard var group = groups[id] else { continue }
            group.memberWindowIDs.formIntersection(alive)
            if group.memberWindowIDs.isEmpty { groups.removeValue(forKey: id) }
            else { groups[id] = group }
        }
    }

    private mutating func removeMember(_ windowID: UInt32, except id: UUID) {
        for other in Array(groups.keys) where other != id {
            groups[other]?.memberWindowIDs.remove(windowID)
            if groups[other]?.memberWindowIDs.isEmpty == true { groups.removeValue(forKey: other) }
        }
    }

    var hasUnresolvedSelection: Bool {
        groups.values.contains { !$0.memberWindowIDs.contains($0.selectedWindowID) }
    }

    var selectedByMember: [UInt32: UInt32] {
        var result: [UInt32: UInt32] = [:]
        // Keep the owner during the interval between selected-tab destruction
        // and the next successful selection observation. No AX writes can be
        // made to that dead element, but its saved placement must survive.
        for group in groups.values {
            for member in group.memberWindowIDs { result[member] = group.selectedWindowID }
        }
        return result
    }
}

/// Capture the logical target before queuing AX work. If its formerly selected
/// tab detaches while the job waits, the operation still belongs to the group.
final class NativeTabOperationRouting: @unchecked Sendable {
    private let lock = NSLock()
    private var groups: [UInt32: UUID] = [:]

    func publish(_ registry: NativeTabRegistry) {
        var next: [UInt32: UUID] = [:]
        for group in registry.groups.values {
            for member in group.memberWindowIDs { next[member] = group.id }
            next[group.selectedWindowID] = group.id
        }
        lock.withLock { groups = next }
    }

    func group(for window: UInt32) -> UUID? { lock.withLock { groups[window] } }

    static func target(window: UInt32, group: UUID?, in registry: NativeTabRegistry) -> UInt32? {
        if let group {
            guard let current = registry.groups[group], current.memberWindowIDs.contains(current.selectedWindowID) else { return nil }
            return current.selectedWindowID
        }
        return registry.selectedByMember[window] ?? window
    }
}
