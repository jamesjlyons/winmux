import AppKit
import AVFoundation
import SwiftUI

private enum MarketingVideoError: Error {
    case captureFailed, encodingFailed
}

/// Captures only the fixture window. Presentation timestamps retain real elapsed
/// time, including any missed capture deadlines; playback is never sped up.
@MainActor
func recordMarketingVideo<Content: View>(
    _ content: Content, to output: URL, size: CGSize, duration: TimeInterval,
    update: (TimeInterval) -> Void
) throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if !app.isRunning { app.finishLaunching() }
    let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
    let window = NSWindow(contentRect: .init(origin: .zero, size: size),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    window.backgroundColor = .black
    window.isOpaque = true
    window.hasShadow = false
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.sharingType = .readOnly
    window.center()
    window.orderFrontRegardless()
    defer { window.orderOut(nil); window.contentView = nil }
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))

    func capture() throws -> CGImage {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
            CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else {
            throw MarketingVideoError.captureFailed
        }
        return image
    }
    let initial = try capture()
    let width = initial.width / 2 * 2
    let height = initial.height / 2 * 2
    let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 6_000_000,
            AVVideoExpectedSourceFrameRateKey: 60,
            AVVideoMaxKeyFrameIntervalKey: 60,
        ],
    ])
    input.expectsMediaDataInRealTime = true
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? MarketingVideoError.encodingFailed }
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else { throw MarketingVideoError.encodingFailed }

    let started = CACurrentMediaTime()
    var frames = 0
    var nextCapture = started
    while CACurrentMediaTime() - started < duration {
        let now = CACurrentMediaTime()
        update(now - started)
        if now < nextCapture {
            RunLoop.main.run(until: Date().addingTimeInterval(nextCapture - now))
        }
        guard input.isReadyForMoreMediaData else {
            guard writer.status == .writing else { throw writer.error ?? MarketingVideoError.encodingFailed }
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            continue
        }
        try autoreleasepool {
            let image = try capture()
            let timestamp = CMTime(seconds: CACurrentMediaTime() - started, preferredTimescale: 60_000)
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let buffer else { throw MarketingVideoError.encodingFailed }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
            else { throw MarketingVideoError.encodingFailed }
            context.draw(image, in: .init(x: 0, y: 0, width: width, height: height))
            guard adaptor.append(buffer, withPresentationTime: timestamp) else {
                throw writer.error ?? MarketingVideoError.encodingFailed
            }
            frames += 1
        }
        nextCapture = max(nextCapture + 1 / 60, CACurrentMediaTime() + 0.001)
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 60_000))
    let finished = DispatchSemaphore(value: 0)
    writer.finishWriting { finished.signal() }
    guard finished.wait(timeout: .now() + 30) == .success, writer.status == .completed else {
        throw writer.error ?? MarketingVideoError.encodingFailed
    }
    print("Recorded \(frames) frames over \(duration)s at \(width)×\(height)")
}
