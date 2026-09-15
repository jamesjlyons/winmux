import AppKit
import SwiftUI

@MainActor
final class WorkspaceSidebarProjectIconPickerController: NSObject, NSPopoverDelegate {
    let projectId: WorkspaceProjectId
    private weak var panel: WorkspaceSidebarPanel?
    private let popover = NSPopover()

    init(project: WorkspaceSidebarProjectViewModel, panel: WorkspaceSidebarPanel, onSelect: @escaping (String?) -> Void) {
        projectId = project.id
        self.panel = panel
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: WorkspaceSidebarProjectIconPicker(
            project: project,
            onSelect: { [weak self] name in
                onSelect(name)
                self?.close()
            },
            onCancel: { [weak self] in self?.close() }
        ))
    }

    func show(at screenPoint: NSPoint) {
        guard let panel, panel.isVisible else { close(); return }
        panel.cancelExpansionWork()
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let point = panel.hostingView.convert(panel.convertPoint(fromScreen: screenPoint), from: nil)
        let width = panel.viewModel.workspaceSidebarVisibleWidth
        let rect = NSRect(
            x: min(max(point.x, 1), max(width - 1, 1)),
            y: min(max(point.y, 1), max(panel.hostingView.bounds.height - 1, 1)),
            width: 1, height: 1
        )
        popover.show(relativeTo: rect, of: panel.hostingView, preferredEdge: .maxX)
    }

    func close() {
        popover.close()
        releasePanel()
    }

    func popoverDidClose(_ notification: Notification) { releasePanel() }

    private func releasePanel() {
        guard let panel, panel.projectIconPicker === self else { return }
        panel.projectIconPicker = nil
        panel.updateMousePassthrough()
        panel.scheduleHoverRecheckSoon()
    }
}

extension WorkspaceSidebarView {
    func beginProjectIconPicker(_ project: WorkspaceSidebarProjectViewModel) {
        guard let panel = currentPanel() else { return }
        finishSidebarSearch(clearText: false)
        finishProjectRename(cancelled: true)
        finishWorkspaceRename(cancelled: true)
        panel.projectIconPicker?.close()
        let controller = WorkspaceSidebarProjectIconPickerController(project: project, panel: panel) { name in
            actions.send(.setProjectIcon(project.id, symbolName: name))
        }
        panel.projectIconPicker = controller
        let point = NSEvent.mouseLocation
        // Present after the context menu has finished tracking and released keyboard focus.
        DispatchQueue.main.async { [weak panel, weak controller] in
            guard let controller, panel?.projectIconPicker === controller else { return }
            controller.show(at: point)
        }
    }
}
