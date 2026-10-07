import SwiftUI
import WorkspaceCore

/// Shared leaves use the same rows as native windows. Split containers project
/// their children directly; only stacks add a window-group header.
struct WorkspaceSidebarSurfaceTreeView: View {
    @Environment(\.workspaceSidebarDensity) private var density
    @Environment(\.workspaceSidebarCompactRows) private var isCompact
    let item: WorkspaceSidebarItemViewModel
    let workspaceName: String
    let targetMonitorScopeId: String
    let selectedSearchTarget: WorkspaceSidebarSearchSelection?
    let isSearchFiltering: Bool
    let actions: WorkspaceSidebarActions
    let onActivate: @MainActor (SurfaceID) -> Void
    var onActivatePin: @MainActor (UUID) -> Void = { _ in }
    var leadingHitInset: CGFloat = 0
    var unfilteredItems: [WorkspaceSidebarItemViewModel] = []
    @State private var isHovered = false

    var body: some View {
        switch item.kind {
        case .pinnedBrowserTab(let tab):
            WorkspaceSidebarPinnedBrowserTabRow(tab: tab, workspaceName: workspaceName,
                selectedSearchTarget: selectedSearchTarget, isSearchFiltering: isSearchFiltering,
                actions: actions, onActivate: onActivatePin)
        case .surface(let surface):
            surfaceButton(surface)
        case .surfaceGroup(let id, let children):
            if BrowserWorkspaceController.shared.sidebarGroupLayout(id) == .stack {
                VStack(alignment: .leading, spacing: 1) {
                    stackHeader(id: id)
                    ForEach(children) { child in
                        childView(child, indent: isCompact ? 0 : density.isNarrow ? 6 : workspaceSidebarTabGroupChildLeadingIndent)
                    }
                }
                .padding(.vertical, 1)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(children) { child in childView(child, indent: leadingHitInset) }
                }
            }
        default: EmptyView()
        }
    }

    private func childView(_ child: WorkspaceSidebarItemViewModel, indent: CGFloat) -> some View {
        WorkspaceSidebarSurfaceTreeView(
            item: child, workspaceName: workspaceName, targetMonitorScopeId: targetMonitorScopeId,
            selectedSearchTarget: selectedSearchTarget, isSearchFiltering: isSearchFiltering,
            actions: actions, onActivate: onActivate, onActivatePin: onActivatePin, leadingHitInset: indent, unfilteredItems: unfilteredItems
        )
    }

    private func surfaceButton(_ surface: WorkspaceSidebarSurfaceItem) -> some View {
        Button { onActivate(surface.surfaceID) } label: {
            WorkspaceSidebarWindowRow(
                title: surface.title, badge: nil, isFocused: surface.isFocused,
                rowHeight: workspaceSidebarWorkspaceRowHeight,
                isHovered: isHovered,
                style: leadingHitInset > 0 ? .tabGroupChild : .window,
                appBundleIds: [surface.appBundleId], appBundlePaths: [surface.appBundlePath],
                favicons: [surface.iconPNGBase64],
                fallbackSystemImage: surface.isBrowser ? "globe" : "app",
                isSelected: surface.isSelected, isKeyboardTarget: selectedSearchTarget == .surface(surface.surfaceID),
                isLoading: surface.isLoading
            )
            .padding(.leading, leadingHitInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(surface.isBrowser ? "Browser tab" : "Native window"): \(surface.title)")
        .help(surface.title)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(WorkspaceSidebarOptionalDragModifier(
            isEnabled: true,
            onChanged: { actions.surfaceDragChanged(.surface(surface.surfaceID), $0) },
            onEnded: { actions.surfaceDragEnded(.surface(surface.surfaceID), $0) }
        ))
        .contextMenu {
            if config.workspaceInteractionMode == .views {
                SurfaceViewActionsMenu(surface: surface.surfaceID, actions: actions)
                Divider()
            }
            if Workspace.existing(byName: workspaceName)?.isIncognito != true {
                Button(surface.isBrowser ? "Pin Tab" : "Pin App") { actions.send(.pinSurface(surface.surfaceID)) }
            }
            Divider()
            SurfaceMoveMenu(subject: .surface(surface.surfaceID), workspaceName: workspaceName,
                            targetMonitorScopeId: targetMonitorScopeId, actions: actions)
            Divider()
            Button("Move Earlier") { actions.send(.reorderSurface(surface.surfaceID, earlier: true)) }
            Button("Move Later") { actions.send(.reorderSurface(surface.surfaceID, earlier: false)) }
            Button("Group with Selected Item") { actions.send(.groupSurfaceWithSelection(surface.surfaceID)) }
            Button("Split Side by Side with Selected Item") { actions.send(.splitSurfaceWithSelection(surface.surfaceID, vertical: false)) }
            Button("Split Above and Below Selected Item") { actions.send(.splitSurfaceWithSelection(surface.surfaceID, vertical: true)) }
            Divider()
            Button(surface.isBrowser ? "Close Tab" : "Close Window") { actions.send(.closeSurface(surface.surfaceID)) }
        }
        .modifier(WorkspaceSidebarHoverClose(surface: surface.surfaceID, title: surface.title, actions: actions,
            selection: .init(isSelected: surface.isSelected, isFocused: surface.isFocused, isHovered: isHovered,
                isKeyboardTarget: selectedSearchTarget == .surface(surface.surfaceID))))
        .onHover { isHovered = $0 }
    }

    private func stackHeader(id: UUID) -> some View {
        let completeItem = unfilteredItems.lazy.compactMap { $0.surfaceGroup(matching: id) }.first ?? item
        let surfaces = completeItem.surfaceItems
        let representative = workspaceSidebarSurfaceStackRepresentative(
            surfaces, activeSurfaceID: BrowserWorkspaceController.shared.surfaceTree.activeSurfaces[id]
        )
        let count = surfaces.count
        return Button {
            if let representative { onActivate(representative.surfaceID) }
        } label: {
            WorkspaceSidebarWindowRow(
                title: "\(count) \(count == 1 ? "window" : "windows")", badge: nil,
                isFocused: surfaces.contains(where: \.isFocused), rowHeight: workspaceSidebarWorkspaceRowHeight,
                isHovered: isHovered,
                style: .tabGroupHeader, appBundleIds: [representative?.appBundleId],
                appBundlePaths: [representative?.appBundlePath], favicons: [representative?.iconPNGBase64],
                fallbackSystemImage: "square.stack"
            )
            .padding(.leading, leadingHitInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tab group of \(count) windows")
        .help("Window group · Active: \(representative?.title ?? "Untitled window")")
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(WorkspaceSidebarOptionalDragModifier(
            isEnabled: true,
            onChanged: { actions.surfaceDragChanged(.group(id), $0) },
            onEnded: { actions.surfaceDragEnded(.group(id), $0) }
        ))
        .contextMenu {
            if Workspace.existing(byName: workspaceName)?.isIncognito != true {
                Button("Pin Group") { actions.send(.pinSurfaceGroup(id)) }
            }
            SurfaceMoveMenu(subject: .group(id), workspaceName: workspaceName,
                            targetMonitorScopeId: targetMonitorScopeId, actions: actions)
            Divider()
            Button("Ungroup Items") { actions.send(.ungroupSurfaces(id)) }
        }
        .onHover { isHovered = $0 }
    }
}
