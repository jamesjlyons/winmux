import Foundation
import SwiftUI

struct WorkspaceSidebarExpandedStatusCard: View {
    let date: Date
    let sectionWidth: CGFloat
    let showsSeconds: Bool
    let showsDate: Bool
    let showsWeekday: Bool
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    private var density: WorkspaceSidebarDensity { .init(sectionWidth: sectionWidth) }
    private var clockSize: CGFloat { density == .minimal ? 23 : density == .narrow ? 28 : 34 }
    private var displaysSeconds: Bool { showsSeconds && sectionWidth >= 200 }
    private var displaysWeekday: Bool { showsWeekday && density != .minimal }

    private var dateLines: WorkspaceSidebarExpandedClockDateLines {
        WorkspaceSidebarExpandedClockDateLines(date: date, locale: locale, calendar: calendar)
    }

    private var accessibilitySummary: String {
        workspaceSidebarExpandedClockAccessibilitySummary(
            date: date,
            showsSeconds: showsSeconds,
            showsDate: showsDate,
            showsWeekday: showsWeekday,
            locale: locale,
            calendar: calendar
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 4) {
                Text(date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(.system(size: clockSize, weight: .regular, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary.opacity(0.90))
                    .lineLimit(1)
                if displaysSeconds {
                    Text(date, format: .dateTime.second(.twoDigits))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary.opacity(0.34))
                        .lineLimit(1)
                        .padding(.top, 7)
                }
            }
            .layoutPriority(1)

            if displaysWeekday {
                dateLine(dateLines.weekday)
            }
            if showsDate {
                dateLine(dateLines.monthAndDay)
            }
        }
        .padding(.horizontal, density.isNarrow ? 8 : 14)
        .padding(.vertical, 8)
        .frame(
            width: sectionWidth,
            height: density.isNarrow ? nil : workspaceSidebarExpandedClockCardHeight(showsDate: showsDate, showsWeekday: showsWeekday),
            alignment: .leading,
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private func dateLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: density.isNarrow ? 11 : 12, weight: .regular))
            .foregroundStyle(Color.primary.opacity(0.48))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .allowsTightening(true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
