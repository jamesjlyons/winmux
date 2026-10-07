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
            ChromeSelectionBackground(state: .init(isSelected: tab.isActive,
                isFocused: tab.isFocused, isHovered: isHovered), cornerRadius: height / 2)
        }
        .accessibilityAddTraits(tab.isActive ? .isSelected : [])
        .opacity(isDragSource ? 0.55 : 1.0)
        .contentShape(Rectangle())
    }

    private var tabForegroundStyle: Color {
        if tab.isActive || isHovered { return .primary }
        return .secondary
    }

}
