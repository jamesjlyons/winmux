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
        let buttonWidth = isCompact ? min(36, sectionWidth) : workspaceSidebarProjectDotFrameWidth
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
                iconName: project.iconName
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
        .accessibilityHint("Click to switch spaces. Drag to rearrange.")
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
    let iconName: String?

    var body: some View {
        WorkspaceSidebarProjectSymbol(iconName: iconName)
            .foregroundStyle(projectColor.opacity(isCurrent ? 0.9 : (isDotHovered ? 0.6 : 0.3)))
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
