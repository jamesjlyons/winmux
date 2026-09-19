import AppKit
import Common
import SwiftUI

@MainActor
enum WorkspaceSidebarSymbolImages {
    static let defaultSymbolName = "circle.fill"
    private static let cache = NSCache<NSString, NSImage>()
    private static var missing: Set<String> = []
    private static let menuCache = NSCache<NSString, NSImage>()

    static func image(named name: String?) -> NSImage? {
        guard let name, !name.isEmpty, !missing.contains(name) else { return nil }
        if let image = cache.object(forKey: name as NSString) { return image }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            missing.insert(name)
            return nil
        }
        cache.countLimit = 512
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    // Native Menu labels tint template images, so supply a color-baked image there.
    static func menuImage(for project: WorkspaceSidebarProjectViewModel) -> NSImage {
        let key = "\(project.id.rawValue)|\(project.iconName ?? "")|\(project.colorHex ?? "auto")" as NSString
        if let image = menuCache.object(forKey: key) { return image }
        let customSymbol = image(named: project.iconName)
        let symbol = customSymbol ?? image(named: defaultSymbolName)
        let size: CGFloat = customSymbol == nil ? 8 : 14
        let result = NSImage(size: NSSize(width: size, height: size))
        let color = NSColor(workspaceSidebarProjectColor(projectId: project.id, configuredHex: project.colorHex))
        result.lockFocus()
        if let symbol {
            let scale = min(size / max(symbol.size.width, 1), size / max(symbol.size.height, 1))
            let width = symbol.size.width * scale
            let height = symbol.size.height * scale
            symbol.draw(in: NSRect(x: (size - width) / 2, y: (size - height) / 2, width: width, height: height))
            color.setFill()
            NSRect(x: 0, y: 0, width: size, height: size).fill(using: .sourceAtop)
        }
        result.unlockFocus()
        result.isTemplate = false
        menuCache.countLimit = 128
        menuCache.setObject(result, forKey: key)
        return result
    }
}

struct WorkspaceSidebarProjectIcon: View {
    let project: WorkspaceSidebarProjectViewModel

    var body: some View {
        WorkspaceSidebarProjectSymbol(iconName: project.iconName)
            .foregroundStyle(workspaceSidebarProjectColor(projectId: project.id, configuredHex: project.colorHex))
            .accessibilityHidden(true)
    }
}

struct WorkspaceSidebarProjectSymbol: View {
    let iconName: String?

    var body: some View {
        let customSymbol = WorkspaceSidebarSymbolImages.image(named: iconName)
        Group {
            if let customSymbol {
                Image(nsImage: customSymbol)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: WorkspaceSidebarSymbolImages.defaultSymbolName)
                    .resizable()
                    .scaledToFit()
            }
        }
        .symbolRenderingMode(.monochrome)
        .frame(width: customSymbol == nil ? 8 : 14, height: customSymbol == nil ? 8 : 14)
        .accessibilityHidden(true)
    }
}

enum WorkspaceSidebarProjectIconError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
            case .unavailable(let name): "The SF Symbol “\(name)” is not available on this Mac."
        }
    }
}

@MainActor
func setWorkspaceSidebarProjectIcon(
    _ projectId: WorkspaceProjectId,
    symbolName: String?,
    persist: (String, String?) throws -> Void = { id, name in
        if !isUnitTest { try persistWorkspaceSidebarProjectIcon(projectId: id, symbolName: name) }
    }
) throws {
    guard workspaceProjects().contains(where: { $0.id == projectId }) else { return }
    let name = symbolName?.trimmingCharacters(in: .whitespacesAndNewlines).takeIf { !$0.isEmpty }
    if let name, WorkspaceSidebarSymbolImages.image(named: name) == nil {
        throw WorkspaceSidebarProjectIconError.unavailable(name)
    }
    try persist(projectId.rawValue, name)
    config.workspaceSidebar.projectIcons[projectId.rawValue] = name
}
