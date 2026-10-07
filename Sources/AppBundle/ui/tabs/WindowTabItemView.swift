import SwiftUI

struct WindowTabItemView: View {
    let tab: WindowTabItemViewModel
    let width: CGFloat
    let height: CGFloat
    let isDragSource: Bool
    let isHovered: Bool

    var body: some View {
        StackTabLabel(title: tab.title, appName: tab.appName, bundleID: tab.appBundleId, bundlePath: tab.appBundlePath,
            isActive: tab.isActive, isFocused: tab.isFocused, width: width, height: height,
            isDragSource: isDragSource, isHovered: isHovered)
    }
}
