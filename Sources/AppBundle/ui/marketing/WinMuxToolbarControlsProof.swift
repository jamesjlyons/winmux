import AppKit
import SwiftUI
import WorkspaceCore

@MainActor
public func renderWinMuxToolbarControlsProofImages(in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for light in [true, false] {
        try renderMarketingView(ToolbarControlsProofScene(light: light),
            to: directory.appendingPathComponent("toolbar-\(light ? "light" : "dark").png"),
            size: .init(width: 1020, height: 440), colorScheme: light ? .light : .dark)
    }
}

private struct ToolbarControlsProofScene: View {
    let light: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Browser controls").font(.system(size: 23, weight: .semibold))
                Text("Production toolbar · Component fixtures · Native window buttons supplied by AppKit in the app")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            row("Pinned extensions · Extensions menu · Downloads · Window actions · Drag handle", width: 956)
            row("Address entry · Command-L selects the full address", width: 956, editing: true)
            HStack(alignment: .top, spacing: 24) {
                row("Narrow pane · Extensions in the menu", width: 430)
                row("Minimum pane · Actions in the context menu", width: 164)
            }
            Text("Pin from the Extensions menu. Right-click a pinned icon to unpin it. Downloads show active transfers.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(32)
        .background {
            LinearGradient(colors: light
                ? [Color(red: 0.89, green: 0.86, blue: 0.96), Color(red: 0.96, green: 0.91, blue: 0.86)]
                : [Color(red: 0.14, green: 0.12, blue: 0.21), Color(red: 0.19, green: 0.19, blue: 0.23)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func row(_ title: String, width: CGFloat, editing: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ToolbarControlsProof(editing: editing)
                .frame(width: width, height: BrowserToolbarController.height)
        }
    }
}

private struct ToolbarControlsProof: NSViewRepresentable {
    let editing: Bool
    func makeNSView(context: Context) -> BrowserToolbarView { BrowserToolbarView() }
    func updateNSView(_ view: BrowserToolbarView, context: Context) {
        var item = BrowserToolbarItem(surfaceID: .browserTab(profile: UUID(), tab: UUID()), frame: .zero,
            url: "https://example.com/projects/design-reference", canGoBack: true, canGoForward: false,
            isLoading: false, isFocused: true)
        item.supportsToolbarActions = true
        item.activeDownloads = 2
        item.pinnedExtensions = [
            .init(id: String(repeating: "a", count: 32), title: "Saved pages", iconPNGBase64: icon("bookmark.fill")),
            .init(id: String(repeating: "b", count: 32), title: "Page tools", iconPNGBase64: icon("wrench.and.screwdriver.fill")),
        ]
        view.update(item, preserveAddress: false)
        if editing { view.update(item, preserveAddress: true) }
    }

    private func icon(_ name: String) -> String? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .medium).applying(.init(paletteColors: [.systemBlue]))),
              let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else { return nil }
        return bitmap.representation(using: .png, properties: [:])?.base64EncodedString()
    }
}
