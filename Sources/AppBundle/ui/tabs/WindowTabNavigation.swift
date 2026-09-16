import Common

enum RelativeTabDestination {
    case window(Window)
    case noGroup
    case boundary
    case invalid
}

@MainActor
func relativeTabDestination(from window: Window?, direction: TabNextPrev, wrapAround: Bool) -> RelativeTabDestination {
    guard let window, let group = window.nearestWindowTabGroup,
          let tab = window.directChild(in: group)
    else { return .noGroup }
    guard let index = tab.ownIndex, !group.children.isEmpty else { return .invalid }
    var next = index + direction.focusOffset
    if !group.children.indices.contains(next) {
        guard wrapAround else { return .boundary }
        next = (next + group.children.count) % group.children.count
    }
    let child = group.children[next]
    guard let destination = child.mostRecentWorkspaceFocusableWindowRecursive ?? child.tabRepresentativeWindow else { return .invalid }
    return .window(destination)
}
