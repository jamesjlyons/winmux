import AppKit

/// Desaturate extension artwork without flattening opaque logos into silhouettes
/// or changing the shared favicon image used elsewhere in the workspace.
@MainActor
final class BrowserToolbarIconCache {
    static let shared = BrowserToolbarIconCache()
    private let images = NSCache<NSString, NSImage>()

    init() {
        images.countLimit = 256
        images.totalCostLimit = 8 * 1024 * 1024
    }

    func image(for encoded: String) -> NSImage? {
        let key = encoded as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let original = WorkspaceSidebarFaviconCache.shared.image(for: encoded),
              let source = original.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: source.width, height: source.height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard let grayscale = context.makeImage() else { return nil }
        let image = NSImage(cgImage: grayscale, size: original.size)
        images.setObject(image, forKey: key, cost: context.bytesPerRow * context.height)
        return image
    }
}
