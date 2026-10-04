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
            if let clockDate {
                clock(date: clockDate)
            } else if showsSeconds {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    clock(date: context.date)
                }
            } else {
                // Match the displayed precision and wake on minute boundaries,
                // rather than rebuilding an unchanged clock 60 times a minute.
                TimelineView(.everyMinute) { context in
                    clock(date: context.date)
                }
            }
        }
        .frame(width: sectionWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(isCompact ? workspaceSidebarCollapseAnimation : workspaceSidebarExpansionAnimation, value: isCompact)
    }

    @ViewBuilder
    private func clock(date: Date) -> some View {
        if menuBarStyle {
            WorkspaceSidebarMenuBarClock(
                date: date,
                sectionWidth: sectionWidth,
                isCompact: isCompact,
                showsSeconds: showsSeconds,
                showsDate: showsDate,
                showsWeekday: showsWeekday,
            )
        } else if isCompact {
            WorkspaceSidebarCompactClockCard(
                date: date,
                sectionWidth: sectionWidth,
                showsSeconds: showsSeconds,
            )
        } else {
            WorkspaceSidebarExpandedStatusCard(
                date: date,
                sectionWidth: sectionWidth,
                showsSeconds: showsSeconds,
                showsDate: showsDate,
                showsWeekday: showsWeekday,
            )
        }
    }
}
