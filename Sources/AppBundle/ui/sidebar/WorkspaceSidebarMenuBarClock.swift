import SwiftUI

/// A small status readout using the same type scale as menu bar labels.
struct WorkspaceSidebarMenuBarClock: View {
    let date: Date
    let sectionWidth: CGFloat
    let isCompact: Bool
    let showsSeconds: Bool
    let showsDate: Bool
    let showsWeekday: Bool
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    private var timeFormat: Date.FormatStyle {
        let format = Date.FormatStyle.dateTime.hour().minute()
        return showsSeconds ? format.second() : format
    }

    private var dateFormat: Date.FormatStyle {
        let format = Date.FormatStyle.dateTime
        if showsDate && showsWeekday { return format.weekday(.abbreviated).month(.abbreviated).day() }
        if showsDate { return format.month(.abbreviated).day() }
        return format.weekday(.wide)
    }

    var body: some View {
        Group {
            if isCompact {
                let components = WorkspaceSidebarClockComponents(date: date, calendar: calendar)
                VStack(spacing: 2) {
                    Text(components.hour)
                    Text(components.minute)
                    if showsSeconds {
                        Text(components.second).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: min(12, sectionWidth * 0.55), weight: .medium))
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    if showsDate || showsWeekday {
                        Text(date, format: dateFormat)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Text(date, format: timeFormat)
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 6)
            }
        }
        .foregroundStyle(.primary)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.vertical, 8)
        .frame(width: sectionWidth, alignment: isCompact ? .center : .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(workspaceSidebarExpandedClockAccessibilitySummary(
            date: date,
            showsSeconds: showsSeconds,
            showsDate: showsDate && !isCompact,
            showsWeekday: showsWeekday && !isCompact,
            locale: locale,
            calendar: calendar
        ))
    }
}
