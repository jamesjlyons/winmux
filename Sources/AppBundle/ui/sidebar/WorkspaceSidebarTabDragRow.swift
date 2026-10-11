import AppKit
import SwiftUI
import WorkspaceCore

struct WorkspaceSidebarStandaloneTabDragRow: ViewModifier {
    let surface: WorkspaceSidebarSurfaceItem?
    let title: String
    let monitor: String
    let allowsReorder: Bool

    func body(content: Content) -> some View {
        if let surface {
            content.modifier(WorkspaceSidebarTabDragRow(surface: surface, monitor: monitor,
                title: title, allowsReorder: allowsReorder))
        } else { content }
    }
}

/// A non-interactive AppKit anchor provides screen geometry before the SwiftUI
/// row is hidden or displaced. It never owns the mouse gesture.
struct WorkspaceSidebarTabDragRow: ViewModifier {
    let surface: WorkspaceSidebarSurfaceItem
    let monitor: String
    var title: String? = nil
    var leadingInset: CGFloat = 0
    var allowsReorder = true
    @ObservedObject private var drag = WorkspaceSidebarTabReorderState.shared
    @Environment(\.workspaceSidebarCompactRows) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.workspaceSidebarTabMotion) private var tabMotion

    func body(content: Content) -> some View {
        let lifted = drag.source == surface.surfaceID && drag.monitor == monitor
        let offset = drag.offset(for: surface.surfaceID.description, monitor: monitor)
        content
            .environment(\.workspaceSidebarTabMotion, lifted ? false : tabMotion)
            .opacity(lifted ? 0 : 1)
            .animation(nil, value: lifted)
            .background(WorkspaceSidebarTabRowAnchor(surface: surface, monitor: monitor,
                title: title ?? surface.title, leadingInset: leadingInset, compact: compact, allowsReorder: allowsReorder))
            .offset(y: offset)
            .animation(reduceMotion ? nil : WorkspaceSidebarTabMotion.reorder, value: offset)
    }
}

private struct WorkspaceSidebarTabRowAnchor: NSViewRepresentable {
    let surface: WorkspaceSidebarSurfaceItem
    let monitor: String
    let title: String
    let leadingInset: CGFloat
    let compact: Bool
    let allowsReorder: Bool

    func makeNSView(context: Context) -> WorkspaceSidebarTabRowAnchorView {
        let view = WorkspaceSidebarTabRowAnchorView()
        WorkspaceSidebarTabRowAnchorView.live.add(view)
        return view
    }

    func updateNSView(_ view: WorkspaceSidebarTabRowAnchorView, context: Context) {
        view.surface = surface
        view.monitor = monitor
        view.title = title
        view.leadingInset = leadingInset
        view.compact = compact
        view.allowsReorder = allowsReorder
    }
}

final class WorkspaceSidebarTabRowAnchorView: NSView {
    static let live = NSHashTable<WorkspaceSidebarTabRowAnchorView>.weakObjects()
    var surface: WorkspaceSidebarSurfaceItem?
    var monitor = ""
    var title = ""
    var leadingInset: CGFloat = 0
    var compact = false
    var allowsReorder = true

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var screenFrame: CGRect? {
        guard !visibleRect.isEmpty else { return nil }
        return unclippedScreenFrame
    }

    var unclippedScreenFrame: CGRect? {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor, bounds.height > 0,
              bounds.width > 0 else { return nil }
        let rect = window.convertToScreen(convert(bounds, to: nil)).monitorFrameNormalized()
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}
