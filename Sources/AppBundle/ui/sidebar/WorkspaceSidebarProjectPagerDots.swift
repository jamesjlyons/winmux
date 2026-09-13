import SwiftUI

extension WorkspaceSidebarProjectPager {
    @ViewBuilder
    func projectDot(
        _ project: WorkspaceSidebarProjectViewModel,
        index: Int,
    ) -> some View {
        let isCurrent = index == currentIndex
        let isDotHovered = hoveredProjectDotId == project.id
        let projectColor = workspaceSidebarProjectColor(projectId: project.id, configuredHex: project.colorHex)
        let buttonWidth = isCompact ? min(36, sectionWidth) : 36
        Button {
            debugWorkspaceSidebarProjectLog(
                "dotButton project=\(project.id.rawValue) selected=\(selectedProjectId.rawValue) currentIndex=\(currentIndex?.description ?? "nil") compact=\(isCompact) projects=\(projects.map(\.id.rawValue))"
            )
            projectTrackScrollTargetId = project.id
            onSelectProject(project.id)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isDotHovered ? projectColor.opacity(0.14) : Color.clear)
                    .frame(width: min(34, buttonWidth), height: 22)
                Capsule(style: .continuous)
                    .fill(projectColor.opacity(isCurrent ? 0.92 : (isDotHovered ? 0.55 : 0.25)))
                    .frame(width: isCurrent ? min(24, max(7, buttonWidth - 6)) : 7, height: 7)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(
                                isCurrent ? Color.white.opacity(0.46) : projectColor.opacity(isDotHovered ? 0.55 : 0.22),
                                lineWidth: isCurrent ? 0.8 : 0.5,
                            )
                    }
                    .overlay {
                        if isCurrent {
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.18), .clear],
                                        startPoint: .top,
                                        endPoint: .bottom,
                                    )
                                )
                                .padding(0.8)
                        }
                    }
                }
                .frame(width: buttonWidth, height: workspaceSidebarProjectDotFrameHeight, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(project.displayName)
        .accessibilityValue(isCurrent ? "Selected" : "")
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        .help(project.displayName)
        .onHover { hovering in
            hoveredProjectDotId = hovering ? project.id : (hoveredProjectDotId == project.id ? nil : hoveredProjectDotId)
        }
        .contextMenu {
            projectContextMenuItems(for: project)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isDotHovered)
    }
}
