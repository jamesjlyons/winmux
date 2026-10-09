import AppKit
import Common
import SwiftUI

extension WorkspaceSidebarView {
    func projectSwipeGesture(expansionProgress: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                handleProjectSwipeChanged(
                    horizontalTranslation: value.translation.width,
                    verticalTranslation: value.translation.height,
                    expansionProgress: expansionProgress,
                )
            }
            .onEnded { value in
                handleProjectSwipeEnded(
                    horizontalTranslation: value.translation.width,
                    verticalTranslation: value.translation.height,
                    expansionProgress: expansionProgress,
                )
            }
    }

    func handleProjectSwipeChanged(
        horizontalTranslation: CGFloat,
        verticalTranslation: CGFloat,
        expansionProgress: CGFloat,
    ) {
        if projectSwipeSettlement != nil {
            resetProjectSwipeWithoutAnimation()
        }
        guard shouldHandleProjectSwipe(
            horizontalTranslation: horizontalTranslation,
            verticalTranslation: verticalTranslation,
            expansionProgress: expansionProgress,
        ) else {
            resetProjectSwipe()
            return
        }
        if projectSwipeStartProjectId == nil,
           let selectedProjectIndex {
            projectSwipeStartProjectId = snapshot.projects[selectedProjectIndex].id
        }
        projectSwipeTranslation = horizontalTranslation
        guard let direction = workspaceSidebarProjectSwipeDirection(
            horizontalTranslation: horizontalTranslation,
            verticalTranslation: verticalTranslation,
        ) else {
            return
        }
        let activeProjectIndex = projectPagerDisplayIndex
        let shouldCreate = shouldCreateWorkspaceSidebarProjectAfterSwipe(
            currentIndex: activeProjectIndex,
            projectCount: snapshot.projects.count,
            direction: direction,
            distance: abs(horizontalTranslation),
            allowsCreation: snapshot.configuration.swipeToCreateProjects,
        )
        let shouldNavigate =
            workspaceSidebarProjectIndexAfterSwipe(
                currentIndex: activeProjectIndex,
                projectCount: snapshot.projects.count,
                direction: direction,
            ) != nil &&
            abs(horizontalTranslation) >= workspaceSidebarProjectSwipeNavigateThreshold
        let shouldCommit = shouldCreate || shouldNavigate
        if shouldCommit && !projectSwipeDidCrossBreakPoint {
            projectSwipeDidCrossBreakPoint = true
            performWorkspaceSidebarProjectHaptic(.alignment)
        } else if !shouldCommit {
            projectSwipeDidCrossBreakPoint = false
        }
    }

    func settleProjectSwipe(to translation: CGFloat, target: WorkspaceProjectId?, direction: Int) {
        let settlement = WorkspaceSidebarProjectSwipeSettlement(target: target, direction: direction)
        projectSwipeSettlement = settlement
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.3
        withAnimation(duration == 0 ? nil : .timingCurve(0.22, 0.72, 0.25, 1, duration: duration)) {
            projectSwipeTranslation = translation
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard projectSwipeSettlement?.id == settlement.id else { return }
            projectSwipeSettlement?.animationFinished = true
            completeProjectSwipeSettlementIfReady()
        }
    }

    func completeProjectSwipeSettlementIfReady() {
        guard projectSwipeSettlement?.isComplete == true else { return }
        resetProjectSwipeWithoutAnimation()
    }

    func shouldHandleProjectSwipe(
        horizontalTranslation: CGFloat,
        verticalTranslation: CGFloat,
        expansionProgress: CGFloat,
    ) -> Bool {
        guard !isOrganizing, !snapshot.projects.isEmpty,
              !isWorkspaceSidebarDragInProgress()
        else {
            return false
        }
        return workspaceSidebarProjectSwipeDirection(
            horizontalTranslation: horizontalTranslation,
            verticalTranslation: verticalTranslation,
        ) != nil
    }
}
