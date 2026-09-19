import AppKit
import Common
import SwiftUI

struct WorkspaceSidebarProjectSelector: View {
    @Environment(\.workspaceSidebarMenuBarStyle) private var menuBarStyle
    let scopes: [WorkspaceSidebarMonitorScopeViewModel]
    let projects: [WorkspaceSidebarProjectViewModel]
    let selectedScopeId: String
    let activeProjectId: WorkspaceProjectId
    let isOrganizing: Bool
    let sectionWidth: CGFloat
    let onSelectScope: (String) -> Void
    let onSelectProject: (WorkspaceProjectId) -> Void
    let onToggleOrganize: () -> Void
    let onCreateProject: () -> Void
    let onRenameProject: (WorkspaceSidebarProjectViewModel) -> Void
    @Binding var renamingProjectId: WorkspaceProjectId?
    @Binding var renamingProjectText: String
    let onCommitRenameProject: @MainActor @Sendable () -> Void
    let onCancelRenameProject: @MainActor @Sendable () -> Void
    let onSetProjectColor: (WorkspaceSidebarProjectViewModel, String?) -> Void
    let onDeleteProject: (WorkspaceSidebarProjectViewModel) -> Void
    let onChooseProjectIcon: (WorkspaceSidebarProjectViewModel) -> Void

    private var activeProject: WorkspaceSidebarProjectViewModel? {
        projects.first { $0.id == activeProjectId }
    }

    var body: some View {
        Group {
            if let project = projects.first(where: { $0.id == renamingProjectId }) {
                WorkspaceSidebarProjectRenameField(
                    project: project, text: $renamingProjectText,
                    onCommit: onCommitRenameProject, onCancel: onCancelRenameProject
                )
            } else {
                Menu {
                    ForEach(projects) { project in
                        projectMenuItem(project, selected: project.id == activeProjectId) {
                            onSelectProject(project.id)
                        }
                    }
                    Divider()
                    Button("New Space", action: onCreateProject)
                    Toggle("Organize", isOn: Binding(get: { isOrganizing }, set: { _ in onToggleOrganize() }))
                        .toggleStyle(.checkbox)
                    Menu("Displays") {
                        ForEach(scopes) { scope in
                            Button {
                                onSelectScope(scope.id)
                            } label: {
                                if scope.id == selectedScopeId {
                                    Label(scope.displayName, systemImage: "checkmark")
                                } else {
                                    Text(scope.displayName)
                                }
                            }
                        }
                    }
                    if let activeProject {
                        Divider()
                        Menu("Manage Space") {
                            Button("Rename Space") { onRenameProject(activeProject) }
                            Button("Choose Icon…") { onChooseProjectIcon(activeProject) }
                            Menu("Color") {
                                Button("Auto") { onSetProjectColor(activeProject, nil) }
                                ForEach(workspaceSidebarProjectColorPresets) { preset in
                                    Button(preset.name) { onSetProjectColor(activeProject, preset.hex) }
                                }
                            }
                            Button("Delete Space", role: .destructive) { onDeleteProject(activeProject) }
                                .disabled(!canDeleteWorkspaceProject(activeProject.id))
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        if let activeProject {
                            Image(nsImage: WorkspaceSidebarSymbolImages.menuImage(for: activeProject))
                                .renderingMode(.original)
                        }
                        Text(activeProject?.displayName ?? "Space")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Space")
                .accessibilityValue(activeProject?.displayName ?? "Space")
                .help("Switch space")
            }
        }
        .padding(.horizontal, 7)
        .frame(width: sectionWidth, height: workspaceSidebarDropdownHeight)
        .background(RoundedRectangle(cornerRadius: workspaceSidebarDropdownCornerRadius).fill(Color.primary.opacity(menuBarStyle ? 0 : 0.07)))
    }

    private func projectMenuItem(_ project: WorkspaceSidebarProjectViewModel, selected: Bool, action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { selected }, set: { _ in action() })) {
            Label {
                Text(project.displayName)
            } icon: {
                Image(nsImage: WorkspaceSidebarSymbolImages.menuImage(for: project))
                    .renderingMode(.original)
            }
        }
        .toggleStyle(.checkbox)
    }
}
