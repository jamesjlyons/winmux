import AppKit

struct WorkspaceSidebarPinReorderTarget: Hashable {
    let id: UUID
    let placement: WorkspaceReorderPlacement
    let isVertical: Bool
}

struct WorkspaceSidebarPinReorderItem {
    let id: UUID
    let frame: CGRect
}

/// Use the unchanged tile frames for insertion hit testing, including the gaps
/// and the empty space after the final tile. Nothing is saved until mouse-up.
func workspaceSidebarPinReorderTarget(at pointer: CGPoint, items: [WorkspaceSidebarPinReorderItem],
                                      shelf: CGRect) -> WorkspaceSidebarPinReorderTarget? {
    guard shelf.contains(pointer), pointer.x.isFinite, pointer.y.isFinite else { return nil }
    let items = items.filter { !$0.frame.intersection(shelf).isEmpty }.sorted {
        if abs($0.frame.midY - $1.frame.midY) > 1 { return $0.frame.midY < $1.frame.midY }
        return $0.frame.midX < $1.frame.midX
    }
    guard let first = items.first, let last = items.last else { return nil }
    let isVertical = shelf.width < first.frame.width * 2 + 6
    func target(_ item: WorkspaceSidebarPinReorderItem, _ placement: WorkspaceReorderPlacement) -> WorkspaceSidebarPinReorderTarget {
        .init(id: item.id, placement: placement, isVertical: isVertical)
    }
    if pointer.y < first.frame.minY { return target(first, .before) }
    if pointer.y > last.frame.maxY { return target(last, .after) }
    guard let nearestRow = items.min(by: { abs($0.frame.midY - pointer.y) < abs($1.frame.midY - pointer.y) }) else { return nil }
    if isVertical { return target(nearestRow, pointer.y < nearestRow.frame.midY ? .before : .after) }
    let row = items.filter { abs($0.frame.midY - nearestRow.frame.midY) < 1 }
    guard let nearest = row.min(by: { abs($0.frame.midX - pointer.x) < abs($1.frame.midX - pointer.x) }) else { return nil }
    return target(nearest, pointer.x < nearest.frame.midX ? .before : .after)
}

@MainActor
func workspaceSidebarPinReorderTarget(at pointer: CGPoint) -> WorkspaceSidebarPinReorderTarget? {
    guard let panel = WorkspaceSidebarPanel.panel(containing: pointer),
          let shelf = panel.dropTargets.last(where: {
              guard case .workspace(let name) = $0.kind else { return false }
              return Workspace.existing(byName: name)?.isPinnedGroup == true && $0.rect.contains(pointer) &&
                  ($0.clipRect?.contains(pointer) ?? true)
          }) else { return nil }
    let shelfFrame = CGRect(x: shelf.rect.minX, y: shelf.rect.minY, width: shelf.rect.width, height: shelf.rect.height)
    let items = panel.dropTargets.compactMap { target -> WorkspaceSidebarPinReorderItem? in
        guard case .pin(let id) = target.kind else { return nil }
        let frame = CGRect(x: target.rect.minX, y: target.rect.minY, width: target.rect.width, height: target.rect.height)
        var visibleFrame = frame.intersection(shelfFrame)
        if let clip = target.clipRect {
            visibleFrame = visibleFrame.intersection(CGRect(x: clip.minX, y: clip.minY, width: clip.width, height: clip.height))
        }
        guard !visibleFrame.isEmpty else { return nil }
        return .init(id: id, frame: frame)
    }
    return workspaceSidebarPinReorderTarget(at: pointer, items: items, shelf: shelfFrame)
}
