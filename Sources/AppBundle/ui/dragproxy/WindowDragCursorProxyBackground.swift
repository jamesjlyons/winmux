import SwiftUI

struct WindowDragCursorProxyBackground: View {
    var isGroup: Bool = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: workspaceSidebarRowCornerRadius, style: .continuous)
        GlassSurface(
            shape: shape,
            style: config.workspaceSidebar.chromeStyle,
            solidColor: config.workspaceSidebar.resolvedSolidChromeColor,
        )
        .overlay {
            shape.fill(Color.primary.opacity(isGroup ? GlassToken.fillActive : GlassToken.fillHover))
        }
        .glassShadow(.resting)
    }
}
