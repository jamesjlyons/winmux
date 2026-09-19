import AppKit
import SwiftUI

struct WorkspaceSidebarWorkspaceReorderTarget: Equatable {
    let name: String
    let placement: WorkspaceReorderPlacement
}

@MainActor
final class WorkspaceSidebarWorkspaceReorderState: ObservableObject {
    static let shared = WorkspaceSidebarWorkspaceReorderState()
    @Published private(set) var sourceName: String?
    @Published private(set) var translationY: CGFloat = 0
    @Published private(set) var destinationIndex: Int?
    @Published private(set) var isSettling = false
    private var layout: WorkspaceSidebarWorkspaceReorderLayout?
    private var lastSnapIndex = 0
    private var settleTask: Task<Void, Never>?
    private let performSnapHaptic: () -> Void

    init(performSnapHaptic: @escaping () -> Void = {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }) {
        self.performSnapHaptic = performSnapHaptic
    }

    var target: WorkspaceSidebarWorkspaceReorderTarget? {
        destinationIndex.flatMap { layout?.target(at: $0) }
    }

    func applies(to monitorScopeId: String) -> Bool {
        layout?.monitorScopeId == nil || layout?.monitorScopeId == monitorScopeId
    }

    func offset(for name: String) -> CGFloat {
        guard let layout else { return 0 }
        if sourceName == name { return translationY }
        return layout.offset(for: name, destinationIndex: destinationIndex ?? layout.sourceIndex)
    }

    func update(
        sourceName: String,
        pointer: CGPoint,
        translation: CGSize = .zero,
        initialLayout: WorkspaceSidebarWorkspaceReorderLayout? = nil,
        emitsHaptic: Bool = true
    ) {
        guard !isSettling else { return }
        if self.sourceName == nil {
            self.sourceName = sourceName
            layout = initialLayout ?? captureWorkspaceSidebarWorkspaceReorderLayout(
                sourceName: sourceName,
                startPoint: CGPoint(x: pointer.x - translation.width, y: pointer.y - translation.height)
            )
            lastSnapIndex = layout?.sourceIndex ?? 0
            beginWorkspaceSidebarItemDrag()
        }
        guard self.sourceName == sourceName else { return }
        translationY = translation.height
        guard let layout, layout.contains(pointer) else {
            destinationIndex = nil
            return
        }
        let nextIndex = layout.snapIndex(translation: translation.height, previousIndex: lastSnapIndex)
        destinationIndex = nextIndex
        if nextIndex != lastSnapIndex {
            lastSnapIndex = nextIndex
            if emitsHaptic { performSnapHaptic() }
            debugWorkspaceSidebarProjectLog("workspaceReorderSnap source=\(sourceName) index=\(nextIndex)")
        }
    }

    func finish(sourceName: String, pointer: CGPoint, translation: CGSize, reduceMotion: Bool, actions: WorkspaceSidebarActions) {
        guard self.sourceName == sourceName, !isSettling else { return }
        update(sourceName: sourceName, pointer: pointer, translation: translation, emitsHaptic: false)
        let destination = target
        isSettling = true
        translationY = layout.map { $0.offset(for: sourceName, destinationIndex: destinationIndex ?? $0.sourceIndex) } ?? 0
        // Settle into the open slot before the model adopts the proposed order.
        // The adapter clears these offsets in the same turn that it publishes that order.
        settleTask = Task { @MainActor [weak self] in
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(180)) }
            guard !Task.isCancelled, let self, self.sourceName == sourceName else { return }
            guard let destination else {
                self.cancel(sourceName: sourceName)
                return
            }
            actions.send(.reorderWorkspace(sourceName, relativeTo: destination.name, placement: destination.placement))
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            // A disabled server or disappearing view must never leave the drag locked.
            self.cancel(sourceName: sourceName)
        }
    }

    func complete(sourceName: String) {
        guard isSettling else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { cancel(sourceName: sourceName) }
    }

    func cancel(sourceName: String) {
        guard self.sourceName == sourceName else { return }
        settleTask?.cancel()
        settleTask = nil
        self.sourceName = nil
        translationY = 0
        destinationIndex = nil
        isSettling = false
        layout = nil
        endWorkspaceSidebarItemDrag()
        WorkspaceSidebarPanel.scheduleHoverRecheckForVisiblePanels()
    }
}
