import AppKit
import SwiftUI
import WorkspaceCore

/// Owns only the proposed order. The tree changes once, after the row has
/// settled; moving out to a split target never commits an intermediate reorder.
@MainActor
final class WorkspaceSidebarTabReorderState: ObservableObject {
    static let shared = WorkspaceSidebarTabReorderState()
    @Published private(set) var source: SurfaceID?
    @Published private(set) var destinationIndex: Int?
    private(set) var monitor = ""
    private(set) var isSettling = false
    private var geometry: WorkspaceSidebarTabDragGeometry?
    private var layout: WorkspaceSidebarTabReorderLayout?
    private var sourceWorkspace: String?
    private var reordersWorkspaces = false
    private var originalNodes: [SurfaceTreeNode] = []
    private var settleTask: Task<Void, Never>?
    private var generation = UUID()
    private weak var sourceAnchor: WorkspaceSidebarTabRowAnchorView?
    private var lastSnapIndex: Int?

    func begin(_ id: SurfaceID, pointer: CGPoint, translation: CGSize) {
        guard source == nil, let panel = WorkspaceSidebarPanel.panel(containing: pointer),
              let sidebar = panel.visibleScreenRectNormalized(),
              let anchor = WorkspaceSidebarTabRowAnchorView.live.allObjects.first(where: {
                  $0.surface?.surfaceID == id && $0.window === panel && $0.screenFrame != nil
              }), let row = anchor.screenFrame, let surface = anchor.surface else { return }
        let controller = BrowserWorkspaceController.shared
        guard controller.canMoveSurface(id), let name = controller.workspaceName(for: id) else { return }
        monitor = panel.monitorScopeId
        sourceAnchor = anchor
        sourceWorkspace = name
        originalNodes = controller.surfaceTree.roots[name] ?? []
        geometry = .init(row: row,
            sidebar: CGRect(x: sidebar.minX, y: sidebar.minY, width: sidebar.width, height: sidebar.height),
            start: CGPoint(x: pointer.x - translation.width, y: pointer.y - translation.height))
        reordersWorkspaces = TrayMenuModel.shared.workspaceSidebarWorkspaces.first { $0.name == name }?.isSingleWindowView == true
        if anchor.allowsReorder {
            if reordersWorkspaces,
               let captured = captureWorkspaceSidebarWorkspaceReorderLayout(sourceName: name, startPoint: pointer) {
                layout = .init(items: captured.items, sourceName: name)
            } else {
                // Only direct siblings participate; nested arrangements keep
                // their structure and all unrelated rows remain stationary.
                let siblings: [SurfaceTreeNode]
                if case .group(_, let children) = controller.surfaceTree.ancestors(of: .surface(id)).last {
                    siblings = children
                } else { siblings = originalNodes }
                let anchors = WorkspaceSidebarTabRowAnchorView.live.allObjects.filter { $0.window === panel }
                let items = siblings.compactMap { node -> WorkspaceSidebarWorkspaceReorderItem? in
                    guard case .surface(let sibling) = node,
                          let frame = anchors.first(where: { $0.surface?.surfaceID == sibling })?.unclippedScreenFrame else { return nil }
                    return .init(name: sibling.description, frame: frame)
                }
                if items.count == siblings.count { layout = .init(items: items, sourceName: id.description) }
            }
        }
        generation = UUID()
        destinationIndex = layout?.sourceIndex
        lastSnapIndex = destinationIndex
        source = id
        WorkspaceSidebarLiftedTabPanel.shared.begin(surface: surface, frame: row,
            title: anchor.title, leadingInset: anchor.leadingInset, compact: anchor.compact)
        update(pointer: pointer)
    }

    @discardableResult
    func update(pointer: CGPoint, emitsHaptic: Bool = true) -> Bool {
        guard source != nil, !isSettling, var geometry else { return false }
        // Scrolling shifts the resting slots, but never the grabbed row relative
        // to the pointer. The hidden source anchor itself has no reorder offset.
        if let frame = sourceAnchor?.unclippedScreenFrame {
            let dy = frame.minY - geometry.row.minY
            if abs(dy) > 0.01 {
                layout = layout?.shifted(by: dy)
                geometry = .init(row: geometry.row.offsetBy(dx: 0, dy: dy), sidebar: geometry.sidebar,
                    start: CGPoint(x: geometry.start.x, y: geometry.start.y + dy))
                self.geometry = geometry
            }
        }
        WorkspaceSidebarLiftedTabPanel.shared.move(to: geometry.frame(at: pointer))
        let inList = geometry.sidebar.contains(pointer) && layout.map { layout in
            let bounds = layout.items.reduce(CGRect.null) { $0.union($1.frame) }
            return pointer.y >= bounds.minY - 20 && pointer.y <= bounds.maxY + 20
                && pointer.x >= bounds.minX - 12 && pointer.x <= bounds.maxX + 12
        } == true
        let next = inList ? layout?.insertionIndex(translation: pointer.y - geometry.start.y) : nil
        if destinationIndex != next { destinationIndex = next }
        // Keep the last slot while outside the list, so returning to the same
        // gap does not tick. Pointer samples within a slot stay silent too.
        if let next, next != lastSnapIndex {
            lastSnapIndex = next
            if emitsHaptic {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
        return inList
    }

    func offset(for key: String, monitor: String) -> CGFloat {
        guard self.monitor == monitor, let layout else { return 0 }
        guard key != layout.source.name else { return 0 }
        return layout.offset(for: key, destinationIndex: destinationIndex ?? layout.sourceIndex)
    }

    func splitProgress(at pointer: CGPoint) -> CGFloat { geometry?.splitProgress(at: pointer) ?? 1 }

    /// Returning true consumes even a release in the source slot, preventing a
    /// normal reorder from falling through to a combination menu.
    func finish(pointer: CGPoint, completion: @escaping @MainActor () -> Void) -> Bool {
        guard source != nil, !isSettling, update(pointer: pointer, emitsHaptic: false), let geometry, let layout,
              let destinationIndex else { return false }
        isSettling = true
        let token = generation
        let target = geometry.row.offsetBy(dx: 0,
            dy: layout.offset(for: layout.source.name, destinationIndex: destinationIndex))
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        WorkspaceSidebarLiftedTabPanel.shared.settle(to: target, reduceMotion: reduceMotion)
        settleTask = Task { @MainActor [weak self] in
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(110)) }
            guard !Task.isCancelled, let self, self.generation == token else { return }
            // Keep visual offsets until the matching model publication adopts
            // the order. A disabled server must also release all drag feedback.
            guard TrayMenuModel.shared.isEnabled else { self.cancel(); completion(); return }
            runWorkspaceSidebarSession {
                guard self.generation == token else { return }
                self.commit(destinationIndex: destinationIndex)
                await updateWorkspaceSidebarModel()
                guard self.generation == token else { return }
                self.cancel()
                completion()
            }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, self.generation == token else { return }
            self.cancel()
            completion()
        }
        return true
    }

    private func commit(destinationIndex: Int) {
        guard let source, let sourceWorkspace, let layout,
              destinationIndex != layout.sourceIndex else { return }
        _ = commitWorkspaceSidebarTabReorder(source: source, workspace: sourceWorkspace, originalNodes: originalNodes,
            layout: layout, destinationIndex: destinationIndex, reordersWorkspaces: reordersWorkspaces)
    }

    func cancel() {
        generation = UUID()
        settleTask?.cancel()
        settleTask = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            source = nil
            destinationIndex = nil
            geometry = nil
            layout = nil
            originalNodes = []
            sourceWorkspace = nil
            isSettling = false
            sourceAnchor = nil
            lastSnapIndex = nil
        }
        WorkspaceSidebarLiftedTabPanel.shared.hide()
    }
}

@MainActor
@discardableResult
func commitWorkspaceSidebarTabReorder(source: SurfaceID, workspace: String, originalNodes: [SurfaceTreeNode],
                                     layout: WorkspaceSidebarTabReorderLayout, destinationIndex: Int,
                                     reordersWorkspaces: Bool, controller: BrowserWorkspaceController = .shared) -> Bool {
    guard layout.items.indices.contains(destinationIndex), destinationIndex != layout.sourceIndex,
          controller.canMoveSurface(source), controller.workspaceName(for: source) == workspace,
          controller.surfaceTree.roots[workspace] == originalNodes else { return false }
    if reordersWorkspaces {
        return reorderWorkspace(workspace, relativeTo: layout.items[destinationIndex].name,
            placement: destinationIndex < layout.sourceIndex ? .before : .after)
    }
    return controller.editOrganization(of: source) { tree in
        for _ in 0..<abs(destinationIndex - layout.sourceIndex) {
            guard tree.reorder(source, earlier: destinationIndex < layout.sourceIndex) else { return false }
        }
        return true
    }
}
