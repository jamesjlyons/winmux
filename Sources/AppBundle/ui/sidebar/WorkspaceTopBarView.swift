import AppKit
import SwiftUI
import WorkspaceCore

/// Shares the sidebar's snapshot and commands; placement never creates another workspace tree.
struct WorkspaceTopBarView: View {
    let snapshot: WorkspaceSidebarSnapshot
    let actions: WorkspaceSidebarActions
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsViews = false
    @State private var initialSearch = ""
    @State private var hovered: String?
    @State private var tabFrames: [String: CGRect] = [:]
    @State private var dragFrames: [String: CGRect] = [:]
    @State private var dragged: String?
    @State private var translation: CGFloat = 0
    @State private var reorderTarget: WorkspaceSidebarWorkspaceReorderTarget?

    private var workspaces: [WorkspaceSidebarWorkspaceViewModel] { workspaceTopBarWorkspaces(snapshot) }
    private var activeSpace: WorkspaceSidebarProjectViewModel? { snapshot.projects.first { $0.id == snapshot.activeProjectId } }
    private var pins: [WorkspaceSidebarPinViewModel] {
        workspaceTopBarPins(snapshot)
    }
    private var selectedView: String? {
        workspaces.first { $0.isVisible && $0.monitorScopeId == snapshot.targetMonitorScopeId }?.name
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 8) {
                spaceMenu.frame(width: min(150, max(76, geometry.size.width * 0.14)))
                if !pins.isEmpty, geometry.size.width > 460 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) { ForEach(pins) { pin in pinButton(pin) } }
                    }
                    .frame(width: min(CGFloat(pins.count) * 34, min(180, geometry.size.width * 0.18)))
                    Divider().frame(height: 20)
                }
                tabs
                Button { openViews() } label: { Image(systemName: "list.bullet").frame(width: 28, height: 28) }
                    .help("Search Views and windows")
                    .accessibilityLabel("Views")
                    .accessibilityIdentifier("winmux.top-tabs.views")
                    .popover(isPresented: $showsViews, arrowEdge: .bottom) {
                        WorkspaceTopViewsMenu(snapshot: snapshot, actions: actions, query: initialSearch, dismiss: { showsViews = false })
                    }
                Button {
                    if snapshot.configuration.showsBrowserControls { actions.send(.newBrowserTab(workspaceName: selectedView)) }
                    else { actions.send(.createWorkspace(projectId: snapshot.activeProjectId, monitorScopeId: snapshot.targetMonitorScopeId)) }
                } label: { Image(systemName: "plus").frame(width: 28, height: 28) }
                    .help(snapshot.configuration.showsBrowserControls ? "New Tab" : "New View")
                    .accessibilityLabel(snapshot.configuration.showsBrowserControls ? "New Tab" : "New View")
                Button { actions.send(.setPlacement(.side)) } label: {
                    Image(systemName: "sidebar.left").frame(width: 28, height: 28)
                }.help("Move tabs to side").accessibilityLabel("Move tabs to side")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if snapshot.configuration.menuBarStyle {
                    WorkspaceSidebarMenuBarSurface(shape: Rectangle())
                } else {
                    GlassSurface(shape: Rectangle(), hasBorder: false, style: snapshot.configuration.chromeStyle,
                        solidColor: snapshot.configuration.resolvedSolidChromeColor)
                }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5) }
        }
        .frame(height: workspaceTopBarHeight)
        .coordinateSpace(name: "workspaceSidebarContent")
        .onPreferenceChange(WorkspaceSidebarDropTargetPreferenceKey.self, perform: actions.setDropTargets)
        .environment(\.colorScheme, snapshot.configuration.chromeColorScheme ?? colorScheme)
        .contextMenu { WorkspaceSidebarContextMenu(configuration: snapshot.configuration, actions: actions) }
        .onChange(of: snapshot.activeProjectId) { _ in showsViews = false; cancelDrag() }
        .onChange(of: workspaces.map(\.name)) { _ in cancelDrag() }
        .onDisappear { cancelDrag(); showsViews = false; actions.setDropTargets([]) }
        .onExitCommand { cancelDrag(); showsViews = false }
        .onReceive(NotificationCenter.default.publisher(for: workspaceSidebarCommandSearchKeyNotification)) { notification in
            guard let panel = notification.object as? WorkspaceSidebarPanel,
                  panel.monitorScopeId == snapshot.targetMonitorScopeId else { return }
            initialSearch = panel.bufferedCommandSidebarSearchKeys.compactMap { key in
                if case .text(let text) = key { return text }; return nil
            }.joined()
            panel.bufferedCommandSidebarSearchKeys = []
            panel.endInlineTextEditing()
            openViews(clearQuery: false)
        }
    }

    private var spaceMenu: some View {
        Menu {
            ForEach(snapshot.projects) { project in
                Button { actions.send(.selectProject(project.id)) } label: {
                    if project.id == snapshot.activeProjectId { Label(project.displayName, systemImage: "checkmark") }
                    else { Text(project.displayName) }
                }
            }
            Divider()
            Button("New Space") { actions.send(.createProject) }
            Button("New View") { actions.send(.createWorkspace(projectId: snapshot.activeProjectId, monitorScopeId: snapshot.targetMonitorScopeId)) }
            if snapshot.monitorScopes.count > 1 {
                Menu("Displays") {
                    ForEach(snapshot.monitorScopes) { scope in
                        Button { actions.send(.selectMonitorScope(scope.id)) } label: {
                            if snapshot.selectedMonitorScopeId == scope.id { Label(scope.displayName, systemImage: "checkmark") }
                            else { Text(scope.displayName) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                if let activeSpace { WorkspaceSidebarProjectIcon(project: activeSpace) }
                Text(activeSpace?.displayName ?? "Space").lineLimit(1)
            }.font(.system(size: 12, weight: .medium))
        }.menuStyle(.borderlessButton).help("Switch space").accessibilityLabel("Space")
    }

    private var tabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspaces) { workspace in tab(workspace).id(workspace.name) }
                    if workspaces.isEmpty { Text("No Views").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 10) }
                }.padding(.horizontal, 2).padding(.vertical, 4)
            }
            .workspaceSidebarDropViewport()
            .coordinateSpace(name: "workspaceTopTabs")
            .onPreferenceChange(WorkspaceTopTabFrames.self) { tabFrames = $0 }
            .onChange(of: selectedView) { name in if let name { proxy.scrollTo(name, anchor: .center) } }
            .onAppear { if let selectedView { proxy.scrollTo(selectedView, anchor: .center) } }
        }
    }

    private func tab(_ workspace: WorkspaceSidebarWorkspaceViewModel) -> some View {
        let selected = workspace.name == selectedView
        let elsewhere = workspaceTopBarViewIsElsewhere(workspace, monitor: snapshot.targetMonitorScopeId)
        return Button { actions.send(.selectWorkspace(workspace.name)) } label: {
            HStack(spacing: 7) {
                WorkspaceTopItemIcon(surface: workspace.viewSurfaces.first)
                Text(workspace.displayName).lineLimit(1).truncationMode(.tail)
                if workspace.viewSurfaceCount > 1 {
                    Image(systemName: "rectangle.split.2x1").foregroundStyle(.secondary)
                    Text("\(workspace.viewSurfaceCount)").foregroundStyle(.secondary).monospacedDigit()
                }
                if elsewhere { Image(systemName: "display").foregroundStyle(.secondary) }
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 12)
            .frame(minWidth: 96, maxWidth: 220)
            .frame(height: 32)
            .background { ChromeSelectionBackground(state: .init(isSelected: selected, isFocused: selected,
                isHovered: hovered == workspace.name), cornerRadius: 16, palette: .sidebar) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(elsewhere)
        .help(elsewhere ? "\(workspace.displayName) — in use on another display" : workspace.displayName)
        .accessibilityLabel(workspace.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("winmux.top-tabs.view.\(workspace.name)")
        .onHover { hovered = $0 ? workspace.name : nil }
        .background { GeometryReader { geo in Color.clear.preference(key: WorkspaceTopTabFrames.self, value: [workspace.name: geo.frame(in: .named("workspaceTopTabs"))]) } }
        .background { GeometryReader { geo in
            Color.clear.preference(key: WorkspaceSidebarDropTargetPreferenceKey.self,
                value: [.init(kind: .workspace(workspace.name), frame: geo.frame(in: .named("workspaceSidebarContent")))])
        } }
        .overlay {
            if snapshot.hoveredWorkspaceName == workspace.name {
                Capsule().strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
            }
        }
        .offset(x: dragged == workspace.name ? translation : 0)
        .zIndex(dragged == workspace.name ? 1 : 0)
        .overlay(alignment: reorderTarget?.placement == .before ? .leading : .trailing) {
            if reorderTarget?.name == workspace.name { Capsule().fill(Color.accentColor).frame(width: 2, height: 24) }
        }
        .highPriorityGesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("workspaceTopTabs"))
            .onChanged { value in
                if dragged == nil { dragged = workspace.name; dragFrames = tabFrames }
                translation = value.translation.width
                reorderTarget = workspaceTopTabReorderTarget(source: workspace.name, locationX: value.location.x, frames: dragFrames)
            }.onEnded { value in
                if dragged == workspace.name, (0...workspaceTopBarHeight).contains(value.location.y),
                   let target = workspaceTopTabReorderTarget(source: workspace.name, locationX: value.location.x, frames: dragFrames) {
                    actions.send(.reorderWorkspace(workspace.name, relativeTo: target.name, placement: target.placement))
                }
                cancelDrag()
            })
        .contextMenu { WorkspaceTopViewContextMenu(workspace: workspace, snapshot: snapshot, actions: actions) }
    }

    private func pinButton(_ pin: WorkspaceSidebarPinViewModel) -> some View {
        Button { actions.send(.selectPin(pin.id)) } label: {
            WorkspaceTopItemIcon(favicon: pin.iconPNGBase64, bundle: pin.bundleIdentifier, path: pin.bundlePath,
                fallback: pin.isGroup ? "rectangle.split.2x1" : pin.isBrowser ? "globe" : "app")
                .frame(width: 30, height: 30)
                .background { ChromeSelectionBackground(state: .init(isSelected: pin.isSelected, isFocused: pin.isFocused), cornerRadius: 9, palette: .sidebar) }
        }
        .help(pin.title).accessibilityLabel("Pinned: \(pin.title)")
        .contextMenu { WorkspaceTopPinContextMenu(pin: pin, snapshot: snapshot, actions: actions) }
    }

    private func openViews(clearQuery: Bool = true) {
        if clearQuery { initialSearch = "" }
        WorkspaceSidebarPanel.panel(for: snapshot.targetMonitorScopeId)?.prepareForInlineTextEditing()
        showsViews = true
    }
    private func cancelDrag() { dragged = nil; translation = 0; dragFrames = [:]; reorderTarget = nil }
}

private struct WorkspaceTopTabFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

struct WorkspaceTopItemIcon: View {
    @ObservedObject private var cache = WorkspaceSidebarFaviconCache.shared
    var favicon: String?
    var bundle: String?
    var path: String?
    var fallback = "app"
    init(favicon: String? = nil, bundle: String? = nil, path: String? = nil, fallback: String = "app") {
        self.favicon = favicon; self.bundle = bundle; self.path = path; self.fallback = fallback
    }
    init(surface: WorkspaceSidebarSurfaceItem?) {
        favicon = surface?.iconPNGBase64; bundle = surface?.appBundleId; path = surface?.appBundlePath
        fallback = surface?.isBrowser == true ? "globe" : "app"
    }
    var body: some View {
        Group {
            if let image = workspaceSidebarIconImage(favicon: favicon, bundleIdentifier: bundle, bundlePath: path) {
                Image(nsImage: image).resizable().scaledToFit()
            } else { Image(systemName: fallback).resizable().scaledToFit().foregroundStyle(.secondary) }
        }.frame(width: 16, height: 16)
            .task(id: favicon) { if let favicon { cache.prepare(favicon) } }
    }
}

struct WorkspaceTopViewContextMenu: View {
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let snapshot: WorkspaceSidebarSnapshot
    let actions: WorkspaceSidebarActions
    var body: some View {
        if workspaceTopBarViewIsElsewhere(workspace, monitor: snapshot.targetMonitorScopeId) {
            Button("Move View to This Display") { actions.send(.overrideWorkspaceInUse(workspace.name)) }
        } else {
            Button("Open View") { actions.send(.selectWorkspace(workspace.name)) }
        }
        Button("Rename View…") { DispatchQueue.main.async { rename() } }
        Button("Pin View") { actions.send(.pinWorkspaceView(workspace.name)) }
        let peers = snapshot.workspaces.filter { $0.projectId == workspace.projectId && !$0.isPinnedGroup }
        if let index = peers.firstIndex(where: { $0.name == workspace.name }) {
            if index > 0 {
                Button("Move Earlier") { actions.send(.reorderWorkspace(workspace.name, relativeTo: peers[index - 1].name, placement: .before)) }
            }
            if index + 1 < peers.count {
                Button("Move Later") { actions.send(.reorderWorkspace(workspace.name, relativeTo: peers[index + 1].name, placement: .after)) }
            }
        }
        if let surface = workspace.viewSurfaces.first, workspace.isSingleWindowView {
            SurfaceViewActionsMenu(surface: surface.surfaceID, actions: actions)
        }
        Divider()
        Button("Close View", role: .destructive) { actions.send(.deleteWorkspace(workspace.name)) }
    }

    private func rename() {
        let alert = NSAlert()
        alert.messageText = "Rename View"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = workspace.displayName
        field.setAccessibilityLabel("View name")
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            actions.send(.renameWorkspace(workspace.name, displayName: field.stringValue))
        }
    }
}

struct WorkspaceTopPinContextMenu: View {
    let pin: WorkspaceSidebarPinViewModel
    let snapshot: WorkspaceSidebarSnapshot
    let actions: WorkspaceSidebarActions
    var body: some View {
        Button("Open") { actions.send(.selectPin(pin.id)) }
        Button("Unpin") { actions.send(.unpin(pin.id)) }
        Menu("Move to Space") {
            ForEach(snapshot.projects.filter { !$0.id.isIncognito }) { project in
                Button(project.displayName) { actions.send(.movePin(pin.id, toSpace: project.id)) }
                    .disabled(snapshot.workspaces.first { $0.name == pin.workspaceName }?.projectId == project.id)
            }
        }
    }
}
