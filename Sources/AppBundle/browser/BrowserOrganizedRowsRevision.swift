import Foundation
import WorkspaceCore

/// Presentation inputs for one workspace. Native rows are already retained by
/// their tree revision; unrelated browser selections do not rebuild these rows.
struct BrowserOrganizedRowsRevision: Equatable {
    let native: [WorkspaceSidebarItemViewModel]
    let browser: [WorkspaceSidebarItemViewModel]
    let roots: [SurfaceTreeNode]
    let layouts: [UUID: SurfaceContainerLayout]
    let selected: Set<SurfaceID>
    let appPaths: [SurfaceID: String]
    let nativeStructure: UInt64?
    let nativeGeometry: UInt64?
}
