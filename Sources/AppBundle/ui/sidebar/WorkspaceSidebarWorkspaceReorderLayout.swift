import Foundation

struct WorkspaceSidebarWorkspaceReorderItem: Equatable {
    let name: String
    let frame: CGRect
}

/// Geometry is captured before any card moves, keeping snap thresholds stable
/// while the neighboring cards animate into their proposed positions.
struct WorkspaceSidebarWorkspaceReorderLayout {
    let items: [WorkspaceSidebarWorkspaceReorderItem]
    let sourceIndex: Int
    let spacing: CGFloat
    let monitorScopeId: String?

    init?(items: [WorkspaceSidebarWorkspaceReorderItem], sourceName: String, monitorScopeId: String? = nil) {
        let items = items.sorted { $0.frame.minY < $1.frame.minY }
        guard let sourceIndex = items.firstIndex(where: { $0.name == sourceName }) else { return nil }
        self.items = items
        self.sourceIndex = sourceIndex
        self.monitorScopeId = monitorScopeId
        spacing = items.count > 1 ? max(0, items[1].frame.minY - items[0].frame.maxY) : 6
    }

    var source: WorkspaceSidebarWorkspaceReorderItem { items[sourceIndex] }

    func contains(_ pointer: CGPoint) -> Bool {
        items.reduce(CGRect.null) { $0.union($1.frame) }.insetBy(dx: -12, dy: -20).contains(pointer)
    }

    func snapIndex(translation: CGFloat, previousIndex: Int) -> Int {
        guard translation.isFinite else { return previousIndex }
        let center = source.frame.midY + translation
        let others = items.filter { $0.name != source.name }
        var index = min(max(previousIndex, 0), others.count)
        let hysteresis: CGFloat = 4
        while index < others.count, center > others[index].frame.midY + hysteresis { index += 1 }
        while index > 0, center < others[index - 1].frame.midY - hysteresis { index -= 1 }
        return index
    }

    func offset(for name: String, destinationIndex: Int) -> CGFloat {
        guard let original = items.first(where: { $0.name == name }), items.indices.contains(destinationIndex) else { return 0 }
        var reordered = items
        reordered.insert(reordered.remove(at: sourceIndex), at: destinationIndex)
        var y = items[0].frame.minY
        for item in reordered {
            if item.name == name { return y - original.frame.minY }
            y += item.frame.height + spacing
        }
        return 0
    }

    func target(at index: Int) -> WorkspaceSidebarWorkspaceReorderTarget? {
        guard items.indices.contains(index), index != sourceIndex else { return nil }
        return WorkspaceSidebarWorkspaceReorderTarget(
            name: items[index].name,
            placement: index < sourceIndex ? .before : .after
        )
    }
}

@MainActor
func captureWorkspaceSidebarWorkspaceReorderLayout(sourceName: String, startPoint: CGPoint) -> WorkspaceSidebarWorkspaceReorderLayout? {
    guard let panel = WorkspaceSidebarPanel.panel(containing: startPoint),
          let panelRect = panel.visibleScreenRectNormalized()
    else { return nil }
    var seen: Set<String> = []
    let items = workspaceSidebarDropTargets.compactMap { target -> WorkspaceSidebarWorkspaceReorderItem? in
        guard case .workspace(let name) = target.kind,
              name == sourceName || canReorderWorkspace(sourceName, relativeTo: name),
              panelRect.minX <= target.rect.center.x, target.rect.center.x <= panelRect.maxX,
              seen.insert(name).inserted
        else { return nil }
        return WorkspaceSidebarWorkspaceReorderItem(
            name: name,
            frame: CGRect(x: target.rect.minX, y: target.rect.minY, width: target.rect.width, height: target.rect.height)
        )
    }
    return WorkspaceSidebarWorkspaceReorderLayout(items: items, sourceName: sourceName, monitorScopeId: panel.monitorScopeId)
}
