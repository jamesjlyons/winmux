import AppKit
import Common
import SwiftUI

struct WorkspaceSidebarProjectSelector: View {
    @Environment(\.workspaceSidebarMenuBarStyle) private var menuBarStyle
    let scopes: [WorkspaceSidebarMonitorScopeViewModel]
    let projects: [WorkspaceSidebarProjectViewModel]
    let selectedScopeId: String
    let activeProjectId: WorkspaceProjectId
    let browsedProjectId: WorkspaceProjectId?
    let sectionWidth: CGFloat
    let onSelectScope: (String) -> Void
    let onSelectProject: (WorkspaceProjectId) -> Void
    let onBrowseProject: (WorkspaceProjectId?) -> Void
    let onCreateProject: () -> Void
    let onRenameProject: (WorkspaceSidebarProjectViewModel) -> Void
    @Binding var renamingProjectId: WorkspaceProjectId?
    @Binding var renamingProjectText: String
    let onCommitRenameProject: @MainActor @Sendable () -> Void
    let onCancelRenameProject: @MainActor @Sendable () -> Void
    let onSetProjectColor: (WorkspaceSidebarProjectViewModel, String?) -> Void
    let onDeleteProject: (WorkspaceSidebarProjectViewModel) -> Void

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
                        Button {
                            onSelectProject(project.id)
                        } label: {
                            if project.id == activeProjectId {
                                Label(project.displayName, systemImage: "checkmark")
                            } else {
                                Text(project.displayName)
                            }
                        }
                    }
                    Divider()
                    Button("New Space", action: onCreateProject)
                    if projects.count > 1 {
                        Menu("Browse alongside…") {
                            if browsedProjectId != nil {
                                Button("Stop Browsing") { onBrowseProject(nil) }
                                Divider()
                            }
                            ForEach(projects.filter { $0.id != activeProjectId }) { project in
                                Button {
                                    onBrowseProject(project.id)
                                } label: {
                                    if project.id == browsedProjectId {
                                        Label(project.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(project.displayName)
                                    }
                                }
                            }
                        }
                    }
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
                        Circle()
                            .fill(workspaceSidebarProjectColor(projectId: activeProjectId, configuredHex: activeProject?.colorHex))
                            .frame(width: 7, height: 7)
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
}
