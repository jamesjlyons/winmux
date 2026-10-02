import SwiftUI

extension WindowTabItemView {
    var tabIconText: String {
        tab.appName.first.map { String($0).uppercased() } ?? "W"
    }

    @ViewBuilder
    func appIcon(size: CGFloat) -> some View {
        if let icon = appIconImage(bundleIdentifier: tab.appBundleId, bundlePath: tab.appBundlePath) {
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
            .foregroundStyle(tab.isActive ? Color.primary : Color.secondary)
            .frame(width: size, height: size, alignment: .center)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(tab.isActive ? 0.10 : 0.06))
            }
            .accessibilityHidden(true)
    }
}
