import SwiftUI

struct WindowTabItemView: View {
    let tab: WindowTabItemViewModel
    let width: CGFloat
    let height: CGFloat
    let isDragSource: Bool
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 6) {
            appIcon(size: 14)

            Text(tab.title)
                .font(.system(size: 12, weight: tab.isActive ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(tabForegroundStyle)
        .padding(.horizontal, 10)
        .frame(width: width, height: height, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: windowTabStripInnerCornerRadius, style: .continuous)
                .fill(tabBackgroundStyle)
        }
        .opacity(isDragSource ? 0.55 : 1.0)
        .contentShape(Rectangle())
    }

    private var tabForegroundStyle: Color {
        if tab.isActive || isHovered { return .primary }
        return .secondary
    }

    private var tabBackgroundStyle: Color {
        if tab.isActive { return Color.primary.opacity(0.10) }
        if isHovered { return Color.primary.opacity(0.055) }
        return .clear
    }
}
