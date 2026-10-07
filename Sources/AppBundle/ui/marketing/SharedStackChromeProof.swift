import AppKit
import SwiftUI
import WorkspaceCore

/// Production stack controls and shell, with fixed document fixtures only.
@MainActor
public func renderSharedStackChromeProof(in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for light in [false, true] {
        for width in [360, 920] {
            try renderMarketingView(SharedStackChromeProofScene(width: CGFloat(width)),
                to: directory.appendingPathComponent("stack-\(width)-\(light ? "light" : "dark").png"),
                size: .init(width: width, height: 320), colorScheme: light ? .light : .dark)
        }
    }
}

private struct SharedStackChromeProofScene: View {
    let width: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    private let group = UUID()
    private let browser = SurfaceID.browserTab(profile: UUID(), tab: UUID())
    private let app = SurfaceID.nativeWindow(UUID())
    private let nested = UUID()

    private var strip: WindowTabStripViewModel {
        let stack = SharedStackChrome(id: group, workspaceName: "Workspace", tabs: [
            .init(id: .surface(browser), surface: browser, title: "Reference library", appName: "Browser",
                  bundleID: nil, bundlePath: nil, symbol: "globe", isActive: true, isFocused: true),
            .init(id: .surface(app), surface: app, title: "Project notes", appName: "TextEdit",
                  bundleID: "com.apple.TextEdit", bundlePath: nil, symbol: nil, isActive: false, isFocused: false),
            .init(id: .group(nested), surface: app, title: "Research · 2 items", appName: "Arrangement",
                  bundleID: nil, bundlePath: nil, symbol: "rectangle.split.2x1", isActive: false, isFocused: false),
        ])
        return .init(id: .shared(group), workspaceName: stack.workspaceName,
            frame: .init(x: 0, y: 0, width: width - 32, height: 36),
            groupFrame: .init(x: 0, y: 0, width: width - 32, height: 234), activeWindowId: nil,
            activeWindowCornerRadius: 16, tabs: [], occludingFloatingWindowFrames: [], sharedStack: stack)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shared stack · Production controls").font(.system(size: 13, weight: .medium))
            ZStack(alignment: .top) {
                WindowTabGroupVisualView(strip: strip)
                VStack(spacing: 0) {
                    SharedStackStripView(stack: strip.sharedStack!, strip: strip).frame(height: 36)
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Reference library").font(.system(size: 23, weight: .semibold))
                        Text("A page, an app window, or an arrangement can be selected from the same stack.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 3).padding(.bottom, 3)
                }
            }.frame(height: 234)
            Spacer(minLength: 0)
        }.padding(16)
            .background {
                (colorScheme == .light ? Color.white : Color.black)
                LinearGradient(colors: [Color.blue.opacity(0.16), Color.purple.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
    }
}
