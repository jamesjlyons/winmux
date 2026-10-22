import AppKit
import Common
import SwiftUI

extension WorkspaceSidebarView {
    func sidebarContent(expansionProgress: CGFloat) -> some View {
        #if DEBUG
        WorkspaceSidebarViewTestHooks.bodyEvaluations += 1
        #endif
        let isCompact = expansionProgress < workspaceSidebarRowsRevealProgress
        let leadingInset = workspaceSidebarOuterLeadingPadding(expansionProgress: expansionProgress, layout: snapshot.configuration)
        let trailingInset = workspaceSidebarOuterTrailingPadding(expansionProgress: expansionProgress, layout: snapshot.configuration)
        let swipeDirection = projectSwipeSettlement?.direction ?? projectSwipeDirection
        let _ = projectSwipeMountRevision
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
            projectSelectorSection(
                expansionProgress: expansionProgress,
                leadingInset: leadingInset,
                trailingInset: trailingInset,
            )

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
                topPadding: 0,
                visibleWorkspacesByProject: filteredWorkspacesByProject,
                swipeDirection: swipeDirection,
            )
            .frame(
                width: workspaceSidebarContentFrameWidth(expansionProgress: expansionProgress),
                alignment: .topLeading
            )
            .frame(maxHeight: .infinity, alignment: .topLeading)

            if isOrganizing {
                EmptyView()
            } else {
                projectPagerSection(
                    expansionProgress: expansionProgress,
                    leadingInset: leadingInset,
                    trailingInset: trailingInset,
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
        .animation(reduceMotion ? nil : WorkspaceSidebarTabMotion.filtering, value: searchText.isEmpty)
        .environment(\.workspaceSidebarSearchQuery, searchText)
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
        .environment(\.colorScheme, snapshot.configuration.menuBarStyle ? colorScheme : (snapshot.configuration.chromeColorScheme ?? colorScheme))
        .environment(\.workspaceSidebarMenuBarStyle, snapshot.configuration.menuBarStyle)
    }
}

extension WorkspaceSidebarView {
    func workspaceSidebarContentFrameWidth(expansionProgress: CGFloat) -> CGFloat {
        max(snapshot.visibleWidth, 0)
    }
}
