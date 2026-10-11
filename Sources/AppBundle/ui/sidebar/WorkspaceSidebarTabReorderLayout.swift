import Foundation

/// Resting geometry is frozen at pickup. Animated neighbors never become hit
/// targets: the floating row's center chooses the nearest reserved slot.
struct WorkspaceSidebarTabReorderLayout {
    let items: [WorkspaceSidebarWorkspaceReorderItem]
    let sourceIndex: Int

    init?(items: [WorkspaceSidebarWorkspaceReorderItem], sourceName: String) {
        let ordered = items.sorted { $0.frame.minY < $1.frame.minY }
        guard let sourceIndex = ordered.firstIndex(where: { $0.name == sourceName }),
              Set(ordered.map(\.name)).count == ordered.count else { return nil }
        self.items = ordered
        self.sourceIndex = sourceIndex
    }

    var source: WorkspaceSidebarWorkspaceReorderItem { items[sourceIndex] }

    func shifted(by delta: CGFloat) -> Self {
        Self(items: items.map { .init(name: $0.name, frame: $0.frame.offsetBy(dx: 0, dy: delta)) },
             sourceName: source.name)!
    }

    func offset(for name: String, destinationIndex: Int) -> CGFloat {
        guard items.indices.contains(destinationIndex),
              let index = items.firstIndex(where: { $0.name == name }) else { return 0 }
        if index == sourceIndex { return sourceOffset(at: destinationIndex) }
        if destinationIndex <= index, index < sourceIndex {
            return source.frame.height + items[index + 1].frame.minY - items[index].frame.maxY
        }
        if sourceIndex < index, index <= destinationIndex {
            return -(source.frame.height + items[index].frame.minY - items[index - 1].frame.maxY)
        }
        return 0
    }

    private func sourceOffset(at index: Int) -> CGFloat {
        let top = index <= sourceIndex ? items[index].frame.minY : items[index].frame.maxY - source.frame.height
        return top - source.frame.minY
    }

    func insertionIndex(translation: CGFloat) -> Int {
        guard translation.isFinite else { return sourceIndex }
        for index in 0..<(items.count - 1) {
            let first = sourceOffset(at: index)
            let next = sourceOffset(at: index + 1)
            if translation < (first + next) / 2 { return index }
        }
        return items.count - 1
    }
}

struct WorkspaceSidebarTabDragGeometry {
    let row: CGRect
    let sidebar: CGRect
    let start: CGPoint

    func frame(at pointer: CGPoint) -> CGRect {
        // Horizontal travel begins at the sidebar edge without a position jump.
        let dx = pointer.x < sidebar.minX ? pointer.x - sidebar.minX
            : max(0, pointer.x - sidebar.maxX)
        return row.offsetBy(dx: dx, dy: pointer.y - start.y)
    }

    func splitProgress(at pointer: CGPoint) -> CGFloat {
        min(1, max(0, sidebar.minX - pointer.x, pointer.x - sidebar.maxX) / 80)
    }
}
