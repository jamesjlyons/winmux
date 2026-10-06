import AppKit

@MainActor
func workspaceSidebarIconImage(favicon: String?, bundleIdentifier: String?, bundlePath: String?) -> NSImage? {
    favicon.flatMap { WorkspaceSidebarFaviconCache.shared.image(for: $0) }
        ?? appIconImage(bundleIdentifier: bundleIdentifier, bundlePath: bundlePath)
}

/// Inventory supplies the current page's icon. Cache its decoded image across
/// ordinary rows, stack headers, and pins without doing network work in views.
@MainActor
final class WorkspaceSidebarFaviconCache {
    static let shared = WorkspaceSidebarFaviconCache()
    private let images = NSCache<NSString, NSImage>()

    init() {
        images.countLimit = 256
        images.totalCostLimit = 8 * 1024 * 1024
    }

    func image(for encoded: String) -> NSImage? {
        let key = encoded as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let data = Data(base64Encoded: encoded), let image = NSImage(data: data) else { return nil }
        let decodedBytes = image.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh * 4 }
        images.setObject(image, forKey: key, cost: max(data.count, decodedBytes))
        return image
    }
}
