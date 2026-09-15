import AppKit
import Common
import SwiftUI

struct WorkspaceSidebarProjectPager: View {
    let projects: [WorkspaceSidebarProjectViewModel]
    let selectedProjectId: WorkspaceProjectId
    let expansionProgress: CGFloat
    let layout: WorkspaceSidebarConfiguration
    let onSelectProject: (WorkspaceProjectId) -> Void
    let onReorderProject: (WorkspaceProjectId, WorkspaceProjectId) -> Void
    let onCreateProject: () -> Void
    let onBeginRenameProject: (WorkspaceSidebarProjectViewModel) -> Void
    let onSetProjectColor: (WorkspaceSidebarProjectViewModel, String?) -> Void
    let onDeleteProject: (WorkspaceSidebarProjectViewModel) -> Void

    @State var isHovered = false
    @State var hoveredProjectDotId: WorkspaceProjectId? = nil
    @State var projectTrackScrollTargetId: WorkspaceProjectId? = nil
    @State var projectTrackContentMinX: CGFloat = 0
    @State var projectTrackContentWidth: CGFloat = 0
    @State var projectTrackViewportWidth: CGFloat = 0
    @GestureState var projectDotDrag: WorkspaceSidebarProjectDotDrag? = nil
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var sectionWidth: CGFloat { workspaceSidebarSectionWidth(expansionProgress, layout: layout) }
    var isCompact: Bool { expansionProgress < workspaceSidebarRowsRevealProgress }
    var currentIndex: Int? {
        projects.firstIndex { $0.id == selectedProjectId } ?? projects.indices.first
    }
    var selectedProject: WorkspaceSidebarProjectViewModel? {
        projects.first { $0.id == selectedProjectId } ?? projects.first
    }
    var pagerHeight: CGFloat {
        isCompact ? compactProjectControlsHeight : workspaceSidebarPagerHeight
    }
    var projectTrackWidth: CGFloat {
        if isCompact {
            return max(sectionWidth - 4, 12)
        }
        return max(sectionWidth, 24)
    }
    var compactProjectControlsHeight: CGFloat {
        let contentHeight = CGFloat(projects.count) * workspaceSidebarProjectDotFrameHeight
        let maxVisibleHeight = workspaceSidebarProjectDotFrameHeight * 5
        return min(max(contentHeight, workspaceSidebarPagerHeight), maxVisibleHeight)
    }

    var body: some View {
        if !projects.isEmpty {
            pagerContent
                .frame(width: sectionWidth, height: pagerHeight, alignment: .bottom)
                .overlayPreferenceValue(WorkspaceSidebarProjectDotAnchorKey.self) { anchors in
                    GeometryReader { geometry in
                        if !isCompact, projectDotDrag == nil,
                           let project = projects.first(where: { $0.id == hoveredProjectDotId }),
                           let anchor = anchors[project.id] {
                            projectTooltip(project, dotFrame: geometry[anchor])
                        }
                    }
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHovered = hovering
                }
                .animation(reduceMotion ? nil : .interactiveSpring(response: 0.24, dampingFraction: 0.86), value: isHovered)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
        }
    }

    private func projectTooltip(_ project: WorkspaceSidebarProjectViewModel, dotFrame: CGRect) -> some View {
        let textWidth = (project.displayName as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        ]).width
        let width = min(ceil(textWidth) + 16, sectionWidth)
        let centerX = min(max(dotFrame.midX, width / 2), sectionWidth - width / 2)
        return Text(project.displayName)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(width: width, height: 24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .position(x: centerX, y: dotFrame.midY - 25)
    }

    var pagerContent: some View {
        Group {
            if isCompact {
                compactProjectIndicator
            } else {
                projectDotTrack
            }
        }
        .frame(width: sectionWidth, height: pagerHeight, alignment: .bottom)
        .contextMenu {
            Button("New Space") {
                onCreateProject()
            }
        }
        .transaction { $0.animation = nil }
    }
}
