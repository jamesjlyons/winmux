import SwiftUI

extension StackTabLabel {
    var tabIconText: String {
        appName.first.map { String($0).uppercased() } ?? "W"
    }

    @ViewBuilder
    func appIcon(size: CGFloat) -> some View {
        if let symbol {
            Image(systemName: symbol).font(.system(size: size - 1))
                .frame(width: size, height: size).accessibilityHidden(true)
        } else if let icon = appIconImage(bundleIdentifier: bundleID, bundlePath: bundlePath) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size, alignment: .center)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityHidden(true)
        } else {
            fallbackIcon(size: size)
        }
    }

    func fallbackIcon(size: CGFloat) -> some View {
        Text(tabIconText)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .frame(width: size, height: size, alignment: .center)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(isActive ? 0.10 : 0.06))
            }
            .accessibilityHidden(true)
    }
}
