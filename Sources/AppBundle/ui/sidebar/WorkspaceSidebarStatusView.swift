import AppKit
import Foundation
import SwiftUI

private struct WorkspaceSidebarClockDateKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    var workspaceSidebarClockDate: Date? {
        get { self[WorkspaceSidebarClockDateKey.self] }
        set { self[WorkspaceSidebarClockDateKey.self] = newValue }
    }
}

struct WorkspaceSidebarStatusView: View {
    @Environment(\.workspaceSidebarMenuBarStyle) private var menuBarStyle
    @Environment(\.workspaceSidebarClockDate) private var clockDate
    let sectionWidth: CGFloat
    let isCompact: Bool
    let showsSeconds: Bool
    let showsDate: Bool
    let showsWeekday: Bool

    var body: some View {
        Group {
            if menuBarStyle {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    WorkspaceSidebarMenuBarClock(
                        date: clockDate ?? context.date,
                        sectionWidth: sectionWidth,
                        isCompact: isCompact,
                        showsSeconds: showsSeconds,
                        showsDate: showsDate,
                        showsWeekday: showsWeekday,
                    )
                }
            } else if isCompact {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    WorkspaceSidebarCompactClockCard(
                        date: clockDate ?? context.date,
                        sectionWidth: sectionWidth,
                        showsSeconds: showsSeconds,
                    )
                }
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    WorkspaceSidebarExpandedStatusCard(
                        date: clockDate ?? context.date,
                        sectionWidth: sectionWidth,
                        showsSeconds: showsSeconds,
                        showsDate: showsDate,
                        showsWeekday: showsWeekday,
                    )
                }
            }
        }
        .frame(width: sectionWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(isCompact ? workspaceSidebarCollapseAnimation : workspaceSidebarExpansionAnimation, value: isCompact)
    }
}
