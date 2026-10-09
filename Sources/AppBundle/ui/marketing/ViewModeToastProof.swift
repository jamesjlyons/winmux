import AppKit
import SwiftUI

@MainActor
public func renderViewModeToastProof(in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for light in [true, false] {
        for reducedTransparency in [false, true] {
            let scene = VStack(spacing: 24) {
                ViewModeToast(mode: .newView, surfaceStyle: reducedTransparency ? .solid : .liquidGlass)
                ViewModeToast(mode: .tile, surfaceStyle: reducedTransparency ? .solid : .liquidGlass)
            }
            .frame(width: 440, height: 260)
            .background(Color(nsColor: .windowBackgroundColor))
            try renderMarketingView(scene,
                to: directory.appendingPathComponent("toast-\(light ? "light" : "dark")\(reducedTransparency ? "-opaque" : "").png"),
                size: .init(width: 440, height: 260), colorScheme: light ? .light : .dark)
        }
    }
}
