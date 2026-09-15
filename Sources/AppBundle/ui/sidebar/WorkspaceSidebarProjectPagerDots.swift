import Common
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
            WorkspaceSidebarProjectDotLabel(
                isCurrent: isCurrent,
                isDotHovered: isDotHovered,
                projectColor: projectColor,
                buttonWidth: buttonWidth,
                menuBarStyle: layout.menuBarStyle
            )
        }
        .anchorPreference(key: WorkspaceSidebarProjectDotAnchorKey.self, value: .bounds) {
            [project.id: $0]
        }
        .buttonStyle(.plain)
        .highPriorityGesture(projectDotReorderGesture(project.id))
        .offset(projectDotOffset(at: index))
        .zIndex(projectDotDrag?.projectId == project.id ? 1 : 0)
        .animation(
            reduceMotion || projectDotDrag?.projectId == project.id ? nil : .easeOut(duration: 0.14),
            value: projectDotOffset(at: index)
        )
        .accessibilityLabel(project.displayName)
        .accessibilityValue(isCurrent ? "Selected" : "")
        .accessibilityHint("Click to switch projects. Drag to rearrange.")
        .accessibilityAction(named: "Move Earlier") { moveProject(project.id, by: -1) }
        .accessibilityAction(named: "Move Later") { moveProject(project.id, by: 1) }
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

private struct WorkspaceSidebarProjectDotLabel: View {
    let isCurrent: Bool
    let isDotHovered: Bool
    let projectColor: Color
    let buttonWidth: CGFloat
    let menuBarStyle: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isDotHovered ? projectColor.opacity(0.14) : Color.clear)
                .frame(width: min(34, buttonWidth), height: 22)
            Capsule(style: .continuous)
                .fill(projectColor.opacity(isCurrent ? 0.92 : (isDotHovered ? 0.55 : 0.25)))
                .frame(width: 7, height: 7)
                .overlay {
                    if isCurrent {
                        Image(systemName: "checkmark")
                            .font(.system(size: 5, weight: .heavy))
                            .foregroundStyle(Color.primary)
                    }
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isCurrent ? Color.primary.opacity(0.46) : projectColor.opacity(isDotHovered ? 0.55 : 0.22),
                            lineWidth: menuBarStyle ? 0 : (isCurrent ? 0.8 : 0.5),
                        )
                }
                .overlay {
                    if isCurrent && !menuBarStyle {
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.primary.opacity(0.18), .clear],
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
}

struct WorkspaceSidebarProjectDotAnchorKey: PreferenceKey {
    static let defaultValue: [WorkspaceProjectId: Anchor<CGRect>] = [:]

    static func reduce(value: inout [WorkspaceProjectId: Anchor<CGRect>], nextValue: () -> [WorkspaceProjectId: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
