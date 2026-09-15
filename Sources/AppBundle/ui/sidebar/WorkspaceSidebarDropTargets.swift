import SwiftUI

enum WorkspaceSidebarDropTargetKind: Equatable {
    case workspace(String)
    case newWorkspace(projectId: WorkspaceProjectId, monitorScopeId: String)
    case monitor(String)
}

struct WorkspaceSidebarDropTarget {
    let kind: WorkspaceSidebarDropTargetKind
    let rect: Rect
    var clipRect: Rect? = nil
}

struct WorkspaceSidebarDropTargetFrame: Equatable {
    let kind: WorkspaceSidebarDropTargetKind
    let frame: CGRect
    var clipFrame: CGRect? = nil
}

struct WorkspaceSidebarDropTargetPreferenceKey: PreferenceKey {
    static let defaultValue: [WorkspaceSidebarDropTargetFrame] = []

    static func reduce(value: inout [WorkspaceSidebarDropTargetFrame], nextValue: () -> [WorkspaceSidebarDropTargetFrame]) {
        value.append(contentsOf: nextValue())
    }
}

@MainActor
func workspaceSidebarDropTarget(at mouseLocation: CGPoint, hitSlop: NSEdgeInsets = NSEdgeInsets()) -> WorkspaceSidebarDropTarget? {
    WorkspaceSidebarPanel.panel(containing: mouseLocation)
        .flatMap { panel in
            panel.dropTargets.last(where: { target in
                (target.clipRect?.contains(mouseLocation) ?? true) &&
                    target.rect.expanded(
                        left: hitSlop.left,
                        right: hitSlop.right,
                        top: hitSlop.top,
                        bottom: hitSlop.bottom
                    ).contains(mouseLocation)
            })
        }
}

func clippedWorkspaceSidebarDropTargets(
    _ targets: [WorkspaceSidebarDropTargetFrame], to viewport: CGRect
) -> [WorkspaceSidebarDropTargetFrame] {
    targets.compactMap { target in
        let clip = (target.clipFrame ?? viewport).intersection(viewport)
        guard !target.frame.intersection(clip).isEmpty else { return nil }
        var target = target
        target.clipFrame = clip
        return target
    }
}

extension View {
    /// Keep the complete card frame for reorder geometry and separately constrain
    /// hit testing to the intersection of its horizontal and vertical viewports.
    func workspaceSidebarDropViewport() -> some View {
        modifier(WorkspaceSidebarDropViewportModifier())
    }
}

private struct WorkspaceSidebarDropViewportModifier: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .transformPreference(WorkspaceSidebarDropTargetPreferenceKey.self) { targets in
                    targets = clippedWorkspaceSidebarDropTargets(targets, to: geometry.frame(in: .named("workspaceSidebarContent")))
                }
        }
    }
}
