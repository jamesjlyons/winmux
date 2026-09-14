import CoreGraphics
import Foundation

private let isVerboseDragLoggingEnabled = ProcessInfo.processInfo.environment["WINMUX_DEBUG_DRAG"] == "1"

@MainActor
func logWindowDragHitTestIfNeeded(signature: @autoclosure () -> String, _ message: @autoclosure () -> String) {
    guard isDebug, isVerboseDragLoggingEnabled else { return }
    let signature = signature()
    guard lastWindowDragHitTestLogSignature != signature else { return }
    lastWindowDragHitTestLogSignature = signature
    logWindowDragLive(message())
}

@MainActor
func logWindowDragIntentIfNeeded(signature: @autoclosure () -> String, _ message: @autoclosure () -> String) {
    guard isDebug, isVerboseDragLoggingEnabled else { return }
    let signature = signature()
    guard lastWindowDragIntentLogSignature != signature else { return }
    lastWindowDragIntentLogSignature = signature
    logWindowDragLive(message())
}

@MainActor
func logWindowDragLive(_ message: @autoclosure () -> String) {
    guard isDebug, isVerboseDragLoggingEnabled else { return }
    fputs("[drag-live] \(message())\n", stderr)
}

func debugDescribeDragPointBucket(_ point: CGPoint) -> String {
    let bucketSize = CGFloat(80)
    let x = Int((point.x / bucketSize).rounded(.down))
    let y = Int((point.y / bucketSize).rounded(.down))
    return "\(x),\(y)"
}
