import SwiftUI
import WorkspaceCore

struct WorkspaceTopViewsMenu: View {
    let snapshot: WorkspaceSidebarSnapshot
    let actions: WorkspaceSidebarActions
    let dismiss: () -> Void
    @State var query: String
    @State private var expanded: Set<String> = []
    @State private var organizing = false
    @State private var keyboardSelection: String?

    init(snapshot: WorkspaceSidebarSnapshot, actions: WorkspaceSidebarActions, query: String = "", dismiss: @escaping () -> Void = {}) {
        self.snapshot = snapshot; self.actions = actions; self.dismiss = dismiss
        _query = State(initialValue: query)
    }

    private var workspaces: [WorkspaceSidebarWorkspaceViewModel] { workspaceTopBarWorkspaces(snapshot, allSpaces: organizing, query: query) }
    private var pins: [WorkspaceSidebarPinViewModel] {
        workspaceTopBarPins(snapshot, allSpaces: organizing, query: query)
    }
    private var spaceName: String { snapshot.projects.first { $0.id == snapshot.activeProjectId }?.displayName ?? "Space" }
    private func showsMembers(_ workspace: WorkspaceSidebarWorkspaceViewModel) -> Bool {
        expanded.contains(workspace.name) || !workspaceSidebarSearchTerms(query).isEmpty
    }
    private var keyboardTargets: [(String, WorkspaceSidebarAction)] {
        pins.map { ($0.id.uuidString, .selectPin($0.id)) } + workspaces.flatMap { workspace -> [(String, WorkspaceSidebarAction)] in
            var targets: [(String, WorkspaceSidebarAction)] = workspaceTopBarViewIsElsewhere(workspace, monitor: snapshot.targetMonitorScopeId) ? [] : [(workspace.name, .selectWorkspace(workspace.name))]
            if showsMembers(workspace), workspace.viewSurfaceCount > 1 {
                targets += workspace.viewSurfaces.map { ($0.surfaceID.description, .selectSurface($0.surfaceID)) }
            }
            return targets
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(organizing ? "Organize Views" : "Views in \(spaceName)")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                if organizing { Button("Done") { organizing = false }.buttonStyle(.plain) }
            }
            WorkspaceTopSearchField(text: $query, move: moveSelection, select: activateKeyboardSelection, cancel: dismiss)
                .frame(height: 28)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if !pins.isEmpty {
                            Text("Pinned").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.top, 4)
                            ForEach(pins) { pin in pinRow(pin).id(pin.id.uuidString) }
                            Divider().padding(.vertical, 5)
                        }
                        if workspaces.isEmpty && pins.isEmpty {
                            Text(query.isEmpty ? "No Views in this Space" : "No matching Views or windows")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 28)
                        }
                        ForEach(workspaces) { workspace in
                            if organizing { spaceLabel(workspace) }
                            viewRow(workspace).id(workspace.name)
                            if showsMembers(workspace), workspace.viewSurfaceCount > 1 {
                                ForEach(workspace.viewSurfaces, id: \.surfaceID) { surface in
                                    memberRow(surface, workspace: workspace).id(surface.surfaceID.description)
                                }
                            }
                        }
                    }
                }.frame(maxHeight: 390)
                .onChange(of: keyboardSelection) { id in if let id { proxy.scrollTo(id) } }
            }
            Divider()
            HStack {
                Button { organizing.toggle() } label: { Label(organizing ? "Current Space" : "Organize…", systemImage: "slider.horizontal.3") }
                Spacer()
                Button { dismiss(); actions.send(.createWorkspace(projectId: snapshot.activeProjectId, monitorScopeId: snapshot.targetMonitorScopeId)) } label: {
                    Label("New View", systemImage: "plus")
                }
            }.buttonStyle(.plain).font(.system(size: 12))
        }
        .environment(\.workspaceSidebarSearchQuery, query)
        .padding(14)
        .frame(width: 320)
        .frame(minHeight: 200, maxHeight: 510)
        .onAppear {
            expanded = Set(workspaces.filter { $0.isVisible && $0.monitorScopeId == snapshot.targetMonitorScopeId }.map(\.name))
        }
        .onChange(of: query) { _ in keyboardSelection = keyboardTargets.first?.0 }
        .onChange(of: organizing) { _ in keyboardSelection = nil }
        .onExitCommand(perform: dismiss)
    }

    private func moveSelection(_ direction: Int) {
        let targets = keyboardTargets
        guard !targets.isEmpty else { return }
        let index = targets.firstIndex { $0.0 == keyboardSelection }
        let next = index.map { min(max($0 + direction, 0), targets.count - 1) }
            ?? (direction > 0 ? 0 : targets.count - 1)
        keyboardSelection = targets[next].0
    }

    private func pinRow(_ pin: WorkspaceSidebarPinViewModel) -> some View {
        Button { dismiss(); actions.send(.selectPin(pin.id)) } label: {
            HStack(spacing: 8) {
                WorkspaceTopItemIcon(favicon: pin.iconPNGBase64, bundle: pin.bundleIdentifier, path: pin.bundlePath,
                    fallback: pin.isGroup ? "rectangle.split.2x1" : pin.isBrowser ? "globe" : "app")
                WorkspaceSidebarSearchTitle(title: pin.title).lineLimit(1)
                Spacer()
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(.horizontal, 8).frame(height: 32)
                .contentShape(Rectangle())
                .background { ChromeSelectionBackground(state: .init(isSelected: pin.isSelected,
                    isKeyboardTarget: keyboardSelection == pin.id.uuidString), cornerRadius: 10, palette: .sidebar) }
        }.buttonStyle(.plain)
        .contextMenu { WorkspaceTopPinContextMenu(pin: pin, snapshot: snapshot, actions: actions) }
    }

    private func viewRow(_ workspace: WorkspaceSidebarWorkspaceViewModel) -> some View {
        let selected = workspace.isVisible && workspace.monitorScopeId == snapshot.targetMonitorScopeId
        let elsewhere = workspaceTopBarViewIsElsewhere(workspace, monitor: snapshot.targetMonitorScopeId)
        return HStack(spacing: 6) {
            Button {
                dismiss()
                actions.send(.selectWorkspace(workspace.name))
            } label: {
                HStack(spacing: 8) {
                    WorkspaceTopItemIcon(surface: workspace.viewSurfaces.first)
                    WorkspaceSidebarSearchTitle(title: workspace.displayName).lineLimit(1)
                    Spacer(minLength: 4)
                    if elsewhere { Image(systemName: "display").foregroundStyle(.secondary) }
                    if workspace.viewSurfaceCount > 1 {
                        Image(systemName: "rectangle.split.2x1").foregroundStyle(.secondary)
                        Text("\(workspace.viewSurfaceCount)").foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(elsewhere)
            if workspace.viewSurfaceCount > 1 {
                Button {
                    if expanded.contains(workspace.name) { expanded.remove(workspace.name) }
                    else { expanded.insert(workspace.name) }
                } label: {
                    Image(systemName: showsMembers(workspace) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium)).frame(width: 20, height: 28)
                }.buttonStyle(.plain).accessibilityLabel("Show windows in \(workspace.displayName)")
            }
        }
        .font(.system(size: 12, weight: selected ? .medium : .regular))
        .padding(.horizontal, 8).frame(height: 34)
        .background { ChromeSelectionBackground(state: .init(isSelected: selected, isFocused: selected,
            isKeyboardTarget: keyboardSelection == workspace.name), cornerRadius: 10, palette: .sidebar) }
        .help(elsewhere ? "In use on another display" : workspace.displayName)
        .contextMenu { WorkspaceTopViewContextMenu(workspace: workspace, snapshot: snapshot, actions: actions) }
    }

    private func memberRow(_ surface: WorkspaceSidebarSurfaceItem, workspace: WorkspaceSidebarWorkspaceViewModel) -> some View {
        Button { dismiss(); actions.send(.selectSurface(surface.surfaceID)) } label: {
            HStack(spacing: 8) {
                WorkspaceTopItemIcon(surface: surface)
                WorkspaceSidebarSearchTitle(title: surface.title).lineLimit(1)
                Spacer()
                if surface.isFocused { Circle().fill(Color.accentColor).frame(width: 4, height: 4) }
            }.font(.system(size: 12)).padding(.leading, 28).padding(.trailing, 8).frame(height: 30)
                .contentShape(Rectangle())
                .background { ChromeSelectionBackground(state: .init(isKeyboardTarget: keyboardSelection == surface.surfaceID.description), cornerRadius: 8, palette: .sidebar) }
        }.buttonStyle(.plain)
        .contextMenu {
            SurfaceMoveMenu(subject: .surface(surface.surfaceID), workspaceName: workspace.name,
                targetMonitorScopeId: snapshot.targetMonitorScopeId, actions: actions)
            SurfaceViewActionsMenu(surface: surface.surfaceID, actions: actions)
            Button("Close Window", role: .destructive) { actions.send(.closeSurface(surface.surfaceID)) }
        }
    }

    @ViewBuilder private func spaceLabel(_ workspace: WorkspaceSidebarWorkspaceViewModel) -> some View {
        if let index = workspaces.firstIndex(where: { $0.name == workspace.name }),
           index == 0 || workspaces[index - 1].projectId != workspace.projectId {
            Text(snapshot.projects.first { $0.id == workspace.projectId }?.displayName ?? "Space")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.top, 8).padding(.horizontal, 8)
        }
    }

    private func activateKeyboardSelection() {
        guard let target = keyboardTargets.first(where: { $0.0 == keyboardSelection }) ?? keyboardTargets.first else { return }
        dismiss(); actions.send(target.1)
    }
}
