import AppKit
import Common

struct TrackpadTabTarget {
    let windowId: UInt32
    let workspaceName: String
    let groupIdentity: ObjectIdentifier
    let members: [ObjectIdentifier]

    @MainActor static func capture() -> TrackpadTabTarget? {
        guard let window = focus.windowOrNil, let group = window.nearestWindowTabGroup,
              group.children.count > 1,
              isUnitTest || NSWorkspace.shared.frontmostApplication?.processIdentifier == window.app.pid
        else { return nil }
        return TrackpadTabTarget(windowId: window.windowId, workspaceName: focus.workspace.name,
            groupIdentity: ObjectIdentifier(group), members: group.children.map(ObjectIdentifier.init))
    }

    @MainActor func resolve(direction: TrackpadSwipeDirection, reversed: Bool) -> (source: Window, destination: Window)? {
        guard let source = focus.windowOrNil, source.windowId == windowId,
              focus.workspace.name == workspaceName, focus.workspace.isVisible,
              let group = source.nearestWindowTabGroup, ObjectIdentifier(group) == groupIdentity,
              group.children.map(ObjectIdentifier.init) == members
        else { return nil }
        let next = (direction == .left) != reversed
        guard case .window(let destination) = relativeTabDestination(from: source,
            direction: next ? .tabNext : .tabPrev, wrapAround: true), destination !== source
        else { return nil }
        return (source, destination)
    }
}
