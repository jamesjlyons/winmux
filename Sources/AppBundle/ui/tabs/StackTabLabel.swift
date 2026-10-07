import SwiftUI

/// Shared tab presentation. Owner IDs belong to the action model, not the pill.
struct StackTabLabel: View {
    let title: String
    let appName: String
    let bundleID: String?
    let bundlePath: String?
    var symbol: String? = nil
    let isActive: Bool
    let isFocused: Bool
    let width: CGFloat
    let height: CGFloat
    let isDragSource: Bool
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 6) {
            appIcon(size: 14)

            Text(title)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(tabForegroundStyle)
        .padding(.horizontal, 10)
        .frame(width: width, height: height, alignment: .leading)
        .background {
            ChromeSelectionBackground(state: .init(isSelected: isActive,
                isFocused: isFocused, isHovered: isHovered), cornerRadius: height / 2)
        }
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .opacity(isDragSource ? 0.55 : 1.0)
        .contentShape(Rectangle())
    }

    private var tabForegroundStyle: Color {
        if isActive || isHovered { return .primary }
        return .secondary
    }

}
