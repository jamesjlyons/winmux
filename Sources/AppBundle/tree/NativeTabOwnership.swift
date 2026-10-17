import Foundation

/// Compute every destination from one model snapshot before changing IDs.
/// This also prevents a tab moved into another group from stealing its source
/// group's owner while the source's new selection is still being discovered.
@MainActor
func nativeTabOwnerAssignments<W: Window>(_ windows: [W], registry: NativeTabRegistry) -> [(NativeTabGroupSnapshot, W)] {
    guard !registry.hasUnresolvedSelection else { return [] }
    let liveGroups = Set(registry.groups.keys)
    return registry.groups.values.compactMap { group in
        let candidates = windows.filter {
            $0.nativeTabGroup?.id == group.id || (group.memberWindowIDs.contains($0.windowId) &&
                ($0.nativeTabGroup.map { !liveGroups.contains($0.id) } ?? true))
        }
        guard let owner = candidates.first(where: { $0.nativeTabGroup?.id == group.id })
            ?? candidates.first(where: { $0.windowId == group.selectedWindowID }) ?? candidates.first else { return nil }
        return (group, owner)
    }
}

@MainActor
func detachedNativeTabDestinations(_ windows: [Window], registry: NativeTabRegistry) -> [UInt32: String] {
    var result: [UInt32: String] = [:]
    for window in windows {
        guard let previous = window.nativeTabGroup, let workspace = window.nodeWorkspace else { continue }
        let detached = previous.memberWindowIDs.intersection(registry.standaloneWindowIDs)
            .subtracting(registry.groups[previous.id]?.memberWindowIDs ?? [])
        for id in detached { result[id] = workspace.name }
    }
    return result
}
