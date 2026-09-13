import Common
import SwiftUI

/// A native window-pane symbol that follows the menu bar's foreground appearance.
struct MenuBarAppIcon: View {
    var body: some View {
        Image(systemName: "rectangle.split.3x1")
            .renderingMode(.template)
            .symbolRenderingMode(.monochrome)
            .accessibilityLabel(winMuxAppDisplayName)
    }
}
