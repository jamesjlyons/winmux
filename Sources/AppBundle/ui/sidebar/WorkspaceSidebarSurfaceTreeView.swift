import SwiftUI
import WorkspaceCore

/// Alpha organization uses the same leaf and drag actions for either owner.
/// Groups organize sidebar items; pane geometry is handled separately by owners.
struct WorkspaceSidebarSurfaceTreeView: View {
    let item: WorkspaceSidebarItemViewModel
    let actions: WorkspaceSidebarActions

    var body: some View {
        switch item.kind {
        case .surface(let surface):
            Button { actions.send(.selectSurface(surface.surfaceID)) } label: {
                HStack(spacing: 6) {
                    Image(systemName: isBrowser(surface.surfaceID) ? "globe" : "macwindow").frame(width: 16)
                    Text(surface.title).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .frame(height: workspaceSidebarWorkspaceRowHeight)
                .background(surface.isFocused ? Color.accentColor.opacity(0.18) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isBrowser(surface.surfaceID) ? "Browser tab" : "Native window"): \(surface.title)")
            .help(surface.title)
            .onDrag { WorkspaceSidebarDragPayload.surface(surface.surfaceID).itemProvider }
            .onDrop(of: [workspaceSidebarDragPayloadType], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                provider.loadDataRepresentation(forTypeIdentifier: workspaceSidebarDragPayloadType.identifier) { data, _ in
                    guard let data, let raw = String(data: data, encoding: .utf8),
                          case .surface(let source) = WorkspaceSidebarDragPayload(encodedValue: raw) else { return }
                    Task { @MainActor in actions.send(.moveSurfaceBefore(source, surface.surfaceID)) }
                }
                return true
            }
            .contextMenu {
                Button("Move Earlier") { actions.send(.reorderSurface(surface.surfaceID, earlier: true)) }
                Button("Move Later") { actions.send(.reorderSurface(surface.surfaceID, earlier: false)) }
                Button("Group with Selected Item") { actions.send(.groupSurfaceWithSelection(surface.surfaceID)) }
                Button("Split Side by Side with Selected Item") { actions.send(.splitSurfaceWithSelection(surface.surfaceID, vertical: false)) }
                Button("Split Above and Below Selected Item") { actions.send(.splitSurfaceWithSelection(surface.surfaceID, vertical: true)) }
                Divider()
                Button(isBrowser(surface.surfaceID) ? "Close Tab" : "Close Window") { actions.send(.closeSurface(surface.surfaceID)) }
            }
        case .surfaceGroup(let id, let children):
            VStack(alignment: .leading, spacing: 1) {
                Label("\(item.surfaceIDs.count) items", systemImage: "square.stack")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .accessibilityLabel("Group of \(item.surfaceIDs.count) items")
                    .contextMenu { Button("Ungroup Items") { actions.send(.ungroupSurfaces(id)) } }
                ForEach(children) { child in
                    WorkspaceSidebarSurfaceTreeView(item: child, actions: actions).padding(.leading, 10)
                }
            }
        default: EmptyView()
        }
    }

    private func isBrowser(_ id: SurfaceID) -> Bool {
        if case .browserTab = id { return true }
        return false
    }
}
