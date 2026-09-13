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
    private var clockSize: CGFloat { density == .minimal ? 25 : density == .narrow ? 32 : 42 }
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
                    .font(.system(size: clockSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.90))
                    .lineLimit(1)
                if displaysSeconds {
                    Text(date, format: .dateTime.second(.twoDigits))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.34))
                        .lineLimit(1)
                        .padding(.top, 9)
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
        .background(
            RoundedRectangle(cornerRadius: workspaceSidebarStatusCornerRadius, style: .continuous)
                .fill(Color.white.opacity(GlassToken.fillResting))
                .overlay {
                    RoundedRectangle(cornerRadius: workspaceSidebarStatusCornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(GlassToken.cardStroke), lineWidth: StrokeToken.hairline)
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private func dateLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: density.isNarrow ? 11 : 15, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.48))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .allowsTightening(true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
