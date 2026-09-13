import Foundation
import SwiftUI

struct WorkspaceSidebarCompactClockCard: View {
    let date: Date
    let sectionWidth: CGFloat
    let showsSeconds: Bool
    private var contentScale: CGFloat { min(1, max(0, sectionWidth / 32)) }

    private var components: WorkspaceSidebarClockComponents {
        WorkspaceSidebarClockComponents(date: date)
    }

    var body: some View {
        GeometryReader { _ in
            let shape = RoundedRectangle(cornerRadius: min(workspaceSidebarStatusCornerRadius, sectionWidth / 3), style: .continuous)
            ZStack(alignment: .bottomLeading) {
                shape
                    .fill(Color.white.opacity(0.06))

                VStack(alignment: .center, spacing: 4) {
                    Text(components.hour)
                        .foregroundStyle(Color.white.opacity(0.90))

                    Text(components.minute)
                        .foregroundStyle(Color.white.opacity(0.90))

                    if showsSeconds {
                        Text(components.second)
                            .foregroundStyle(Color.white.opacity(0.66))
                    }
                }
                .font(.system(size: max(1, 19 * contentScale), weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                shape
                    .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)
            }
            .clipShape(shape)
        }
        .frame(width: sectionWidth, alignment: .leading)
        .frame(height: (showsSeconds ? 92 : 68) * contentScale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(workspaceSidebarCompactClockAccessibilitySummary(
            date: date,
            showsSeconds: showsSeconds,
        )))
    }
}

func workspaceSidebarCompactClockAccessibilitySummary(date: Date, showsSeconds: Bool) -> String {
    showsSeconds
        ? date.formatted(date: .omitted, time: .standard)
        : date.formatted(date: .omitted, time: .shortened)
}
