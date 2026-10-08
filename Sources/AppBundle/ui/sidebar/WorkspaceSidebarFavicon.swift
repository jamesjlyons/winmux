import AppKit
import ImageIO
import Combine

@MainActor
func workspaceSidebarIconImage(favicon: String?, bundleIdentifier: String?, bundlePath: String?) -> NSImage? {
    favicon.flatMap { WorkspaceSidebarFaviconCache.shared.image(for: $0) }
        ?? appIconImage(bundleIdentifier: bundleIdentifier, bundlePath: bundlePath)
}

/// Inventory supplies the current page's icon. Cache its decoded image across
/// ordinary rows, stack headers, and pins without doing network work in views.
@MainActor
final class WorkspaceSidebarFaviconCache: ObservableObject {
    static let shared = WorkspaceSidebarFaviconCache()
    @Published private(set) var revision: UInt64 = 0
    private let images = NSCache<NSString, NSImage>()
    private let invalid = NSCache<NSString, NSNumber>()
    private let queue = DispatchQueue(label: "WinMux.favicon.decode", qos: .userInitiated)
    private var pending: [String: [@MainActor () -> Void]] = [:]
    private let onPrepared: @MainActor () -> Void
    private(set) var decodeCount = 0

    init(onPrepared: @escaping @MainActor () -> Void = {}) {
        self.onPrepared = onPrepared
        images.countLimit = 256
        images.totalCostLimit = 8 * 1024 * 1024
        invalid.countLimit = 256
    }

    func image(for encoded: String) -> NSImage? {
        if let cached = images.object(forKey: encoded as NSString) { return cached }
        return nil
    }

    /// One serial worker and at most 256 queued icons. A view never decodes PNG
    /// data while rendering, and repeated rows share the same in-flight work.
    func prepare(_ encoded: String, completion: (@MainActor () -> Void)? = nil) {
        let key = encoded as NSString
        guard images.object(forKey: key) == nil, invalid.object(forKey: key) == nil else { completion?(); return }
        if pending[encoded] != nil { if let completion { pending[encoded]?.append(completion) }; return }
        guard encoded.utf8.count <= 131_072 else {
            invalid.setObject(true, forKey: key); completion?(); return
        }
        guard pending.count < 256 else { completion?(); return }
        pending[encoded] = completion.map { [$0] } ?? []
        decodeCount += 1
        queue.async { [weak self] in
            let decoded = DecodedSidebarFavicon(encoded)
            DispatchQueue.main.async {
                guard let self else { return }
                if let cgImage = decoded.image {
                    let image = NSImage(cgImage: cgImage, size: .init(width: cgImage.width, height: cgImage.height))
                    self.images.setObject(image, forKey: encoded as NSString, cost: cgImage.bytesPerRow * cgImage.height)
                } else { self.invalid.setObject(true, forKey: encoded as NSString) }
                let completions = self.pending.removeValue(forKey: encoded) ?? []
                completions.forEach { $0() }
                self.revision &+= 1
                self.onPrepared()
            }
        }
    }

    func prepareAndWait(_ encoded: String) async {
        await withCheckedContinuation { continuation in prepare(encoded) { continuation.resume() } }
    }
}

/// ImageIO creates immutable pixels on the worker; AppKit ownership stays on
/// the main actor. Thumbnail decoding also bounds untrusted image dimensions.
private struct DecodedSidebarFavicon: @unchecked Sendable {
    let image: CGImage?
    init(_ encoded: String) {
        guard let data = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { image = nil; return }
        image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}
