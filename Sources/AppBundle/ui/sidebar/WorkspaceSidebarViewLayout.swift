import AppKit
import Common
import SwiftUI

extension WorkspaceSidebarView {
    func sidebarContent(expansionProgress: CGFloat) -> some View {
        let isCompact = expansionProgress < workspaceSidebarRowsRevealProgress
        let leadingInset = workspaceSidebarOuterLeadingPadding(expansionProgress: expansionProgress, layout: snapshot.configuration)
        let trailingInset = workspaceSidebarOuterTrailingPadding(expansionProgress: expansionProgress, layout: snapshot.configuration)
        let showsProjectSelector = !isCompact
        let projectSwipeDirection = workspaceSidebarProjectSwipeDirection(
            horizontalTranslation: projectSwipeTranslation,
            verticalTranslation: 0,
            minimumDistance: 1,
        )
        let activeProjectIndex = projectPagerDisplayIndex
        let projectSwipeProgress = workspaceSidebarProjectEdgeCreationProgress(
            currentIndex: activeProjectIndex,
            projectCount: snapshot.projects.count,
            direction: projectSwipeDirection,
            distance: abs(projectSwipeTranslation),
            allowsCreation: snapshot.configuration.swipeToCreateProjects,
        )
        let hasSwipeTarget = projectSwipeDirection.flatMap { direction in
            workspaceSidebarProjectIndexAfterSwipe(
                currentIndex: activeProjectIndex,
                projectCount: snapshot.projects.count,
                direction: direction,
            )
        } != nil
        let projectSwitchProgress = hasSwipeTarget
            ? workspaceSidebarProjectSwipeSwitchProgress(distance: abs(projectSwipeTranslation))
            : 0
        let visibleWorkspacesByProject = workspaceSidebarVisibleWorkspacesByProject(
            workspaces: snapshot.workspaces,
            selectedScopeId: snapshot.selectedMonitorScopeId,
            focusedMonitorScopeId: snapshot.focusedMonitorScopeId,
        )
        let filteredWorkspacesByProject = workspaceSidebarFilteredWorkspacesByProject(
            visibleWorkspacesByProject,
            projects: snapshot.projects,
            query: searchText,
        )

        return VStack(alignment: .leading, spacing: 0) {
            if showsProjectSelector {
                projectSelectorSection(
                    expansionProgress: expansionProgress,
                    leadingInset: leadingInset,
                    trailingInset: trailingInset,
                )
            }

            if !isCompact, !searchText.isEmpty {
                sidebarSearchSection(
                    expansionProgress: expansionProgress,
                    leadingInset: leadingInset,
                    trailingInset: trailingInset,
                )
            }

            projectPagerContent(
                expansionProgress: expansionProgress,
                leadingInset: leadingInset,
                trailingInset: trailingInset,
                topPadding: showsProjectSelector ? 0 : max(snapshot.configuration.topPadding, leadingInset),
                visibleWorkspacesByProject: filteredWorkspacesByProject,
                swipeDirection: projectSwipeDirection,
            )
            .frame(
                width: workspaceSidebarContentFrameWidth(expansionProgress: expansionProgress),
                alignment: .topLeading
            )
            .frame(maxHeight: .infinity, alignment: .topLeading)

            if isOrganizing {
                EmptyView()
            } else if (isSidebarCollapsing && !isCompact) || (isSidebarExpanding && isCompact) {
                let compactProjectReserveHeight = min(
                    max(CGFloat(snapshot.projects.count) * workspaceSidebarProjectDotFrameHeight, workspaceSidebarPagerHeight),
                    workspaceSidebarProjectDotFrameHeight * 5
                )
                Color.clear
                    .frame(height: isCompact ? compactProjectReserveHeight + 8 : workspaceSidebarCollapseReservedProjectPagerHeight)
            } else {
                projectPagerSection(
                    expansionProgress: expansionProgress,
                    leadingInset: leadingInset,
                    trailingInset: trailingInset,
                    swipeDirection: projectSwipeDirection,
                    switchProgress: projectSwitchProgress,
                    edgeProgress: projectSwipeProgress,
                )
            }

            if snapshot.configuration.showsClock {
                statusSection(
                    expansionProgress: expansionProgress,
                    isCompact: isCompact,
                    leadingInset: leadingInset,
                    trailingInset: trailingInset,
                )
            }

            Color.clear
                .frame(height: workspaceSidebarFooterBottomPadding(
                    showsClock: snapshot.configuration.showsClock,
                ))
        }
        .coordinateSpace(name: "workspaceSidebarContent")
        .onPreferenceChange(WorkspaceSidebarDropTargetPreferenceKey.self) { frames in
            actions.setDropTargets(frames)
        }
        .background {
            sidebarSurface(in: sidebarShape)
                .contentShape(Rectangle())
                .onTapGesture {
                    NotificationCenter.default.post(name: workspaceSidebarDismissProjectMenusNotification, object: nil)
                }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(snapshot.configuration.menuBarStyle ? 0 : GlassToken.separatorOpacity))
                .frame(width: 0.5)
        }
        .clipShape(sidebarShape)
        .overlay {
            sidebarSwipeCaptureOverlay(expansionProgress: expansionProgress)
        }
        .overlay(alignment: .trailing) {
            if expansionProgress >= 1 {
                WorkspaceSidebarResizeHandle(monitorScopeId: snapshot.targetMonitorScopeId)
                    .frame(width: 8)
                    .frame(maxHeight: .infinity)
                    .help("Drag to resize. Double-click to reset width. Escape to cancel.")
                    .accessibilityLabel("Resize sidebar")
            }
        }
        .environment(\.colorScheme, snapshot.configuration.menuBarStyle ? colorScheme : .dark)
        .environment(\.workspaceSidebarMenuBarStyle, snapshot.configuration.menuBarStyle)
    }
}

private let workspaceSidebarCollapseReservedProjectPagerHeight = workspaceSidebarPagerHeight + 10

extension WorkspaceSidebarView {
    func workspaceSidebarContentFrameWidth(expansionProgress: CGFloat) -> CGFloat {
        max(snapshot.visibleWidth, 0)
    }
}
