import SwiftUI

enum WorkspaceSidebarDensity {
    case full, narrow, minimal

    init(sectionWidth: CGFloat) {
        self = sectionWidth < 116 ? .minimal : sectionWidth < 176 ? .narrow : .full
    }

    var isNarrow: Bool { self != .full }
}

private struct WorkspaceSidebarDensityKey: EnvironmentKey {
    static let defaultValue = WorkspaceSidebarDensity.full
}

extension EnvironmentValues {
    var workspaceSidebarDensity: WorkspaceSidebarDensity {
        get { self[WorkspaceSidebarDensityKey.self] }
        set { self[WorkspaceSidebarDensityKey.self] = newValue }
    }
}

func clampedWorkspaceSidebarWidth(_ width: CGFloat, collapsedWidth: Int, availableWidth: CGFloat) -> Int {
    let lower = max(120, collapsedWidth + 1)
    let upper = max(lower, min(480, Int(availableWidth.rounded(.down))))
    guard width.isFinite else { return lower }
    return Int(min(max(width.rounded(), CGFloat(lower)), CGFloat(upper)))
}
