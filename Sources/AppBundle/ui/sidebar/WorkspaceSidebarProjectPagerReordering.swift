import SwiftUI

struct WorkspaceSidebarProjectDotDrag: Equatable {
    let projectId: WorkspaceProjectId
    let translation: CGSize
}

func workspaceSidebarProjectReorderIndex(sourceIndex: Int, translation: CGFloat, stride: CGFloat, count: Int) -> Int {
    guard count > 0, stride > 0, translation.isFinite else { return sourceIndex }
    let destination = CGFloat(sourceIndex) + (translation / stride).rounded()
    return Int(min(max(destination, 0), CGFloat(count - 1)))
}

extension WorkspaceSidebarProjectPager {
    private var projectDotStride: CGFloat { isCompact ? workspaceSidebarProjectDotFrameHeight : 40 }

    private func reorderIndex(for projectId: WorkspaceProjectId, translation: CGSize) -> Int? {
        guard let sourceIndex = projects.firstIndex(where: { $0.id == projectId }) else { return nil }
        return workspaceSidebarProjectReorderIndex(
            sourceIndex: sourceIndex,
            translation: isCompact ? translation.height : translation.width,
            stride: projectDotStride,
            count: projects.count,
        )
    }

    func projectDotReorderGesture(_ projectId: WorkspaceProjectId) -> some Gesture {
        // Global coordinates keep the drag stable as the dot follows the pointer.
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($projectDotDrag) { value, state, _ in
                state = WorkspaceSidebarProjectDotDrag(projectId: projectId, translation: value.translation)
            }
            .onEnded { value in
                guard let targetIndex = reorderIndex(for: projectId, translation: value.translation),
                      projects[targetIndex].id != projectId
                else { return }
                onReorderProject(projectId, projects[targetIndex].id)
            }
    }

    func projectDotOffset(at index: Int) -> CGSize {
        guard let drag = projectDotDrag,
              let sourceIndex = projects.firstIndex(where: { $0.id == drag.projectId }),
              let targetIndex = reorderIndex(for: drag.projectId, translation: drag.translation)
        else { return .zero }

        let offset: CGFloat
        if index == sourceIndex {
            let translation = isCompact ? drag.translation.height : drag.translation.width
            offset = min(max(translation, -CGFloat(sourceIndex) * projectDotStride), CGFloat(projects.count - 1 - sourceIndex) * projectDotStride)
        } else if sourceIndex < index && index <= targetIndex {
            offset = -projectDotStride
        } else if targetIndex <= index && index < sourceIndex {
            offset = projectDotStride
        } else {
            offset = 0
        }
        return isCompact ? CGSize(width: 0, height: offset) : CGSize(width: offset, height: 0)
    }

    func moveProject(_ projectId: WorkspaceProjectId, by direction: Int) {
        guard let sourceIndex = projects.firstIndex(where: { $0.id == projectId }),
              projects.indices.contains(sourceIndex + direction)
        else { return }
        onReorderProject(projectId, projects[sourceIndex + direction].id)
    }
}
