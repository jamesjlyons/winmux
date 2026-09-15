import AppBundle
import Foundation

@main
struct MarketingRendererCommand {
    @MainActor
    static func main() throws {
        let arguments = CommandLine.arguments.dropFirst()
        let isSafariProof = arguments.contains("--safari-proof")
        let isAppsProof = arguments.contains("--apps-proof")
        let isSafariPlasticityProof = arguments.contains("--safari-plasticity-proof")
        let isSidebarProof = arguments.contains("--sidebar-proof")
        let isMenuBarProof = arguments.contains("--menu-bar-proof")
        let isProjectIconProof = arguments.contains("--project-icon-proof")
        let outputPath = arguments.first(where: { !$0.hasPrefix("--") })
            ?? "resources/marketing/winmux-card-collage-swiftui.png"
        let outputURL = URL(fileURLWithPath: outputPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if arguments.contains("--sidebar-context-proof") {
            try renderWinMuxSidebarContextProofImages(in: outputURL)
        } else if isSidebarProof || isMenuBarProof || isProjectIconProof {
            try renderWinMuxSidebarProofImages(in: outputURL, menuBarOnly: isMenuBarProof, projectIcons: isProjectIconProof)
        } else if isSafariPlasticityProof {
            try renderWinMuxSafariPlasticityProofImage(to: outputURL)
        } else if isAppsProof {
            try renderWinMuxAppsProofImage(to: outputURL)
        } else if isSafariProof {
            try renderWinMuxSafariProofImage(to: outputURL)
        } else {
            try renderWinMuxMarketingImage(to: outputURL)
        }
        print(outputURL.path)
    }
}
