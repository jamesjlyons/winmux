import AppKit
import QuartzCore

/// Animates snapshots because another app's window cannot host our Core Animation layers.
@MainActor
final class DoubleSidedWindowController {
    static let shared = DoubleSidedWindowController()
    private struct FlipAnimation {
        let panel: NSPanel
        let faces: [(windowId: UInt32, layer: CALayer, hiddenAngle: Double)]
    }
    private var animation: FlipAnimation?
    private var completionTask: Task<Void, Never>?
    private let backdropPadding: CGFloat = 64

    var isAnimating: Bool { animation != nil }

    func flip(_ window: Window) {
        guard TrayMenuModel.shared.isEnabled,
              let group = window.nearestWindowTabGroup,
              group.usesDoubleSidedWindows,
              group.tabActiveWindow === window,
              let other = group.children.compactMap({ $0 as? Window }).first(where: { $0 !== window })
        else { return }
        if animation?.faces.contains(where: { $0.windowId == window.windowId }) == true,
           retargetAnimation(to: other.windowId) {
            focusWindowFromTabStrip(other.windowId, fallbackWorkspace: focus.workspace.name)
            return
        }
        cancelAnimation()
        let canAnimate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && CGPreflightScreenCaptureAccess()
        let captureInterval = signposter.beginInterval("Flip snapshot capture")
        let front = canAnimate ? snapshot(window.windowId) : nil
        let back = canAnimate ? snapshot(other.windowId) : nil
        let rect = window.lastAppliedLayoutPhysicalRect
        let background = rect.flatMap { rect in front != nil && back != nil ? CGWindowListCreateImage(
               CGRect(x: rect.topLeftX, y: rect.topLeftY, width: rect.width, height: rect.height)
                   .insetBy(dx: -backdropPadding, dy: -backdropPadding),
               .optionOnScreenBelowWindow, window.windowId, [.nominalResolution]
           ) : nil }
        signposter.endInterval("Flip snapshot capture", captureInterval)
        if let front, let back, let background, let rect {
            animate(front: front, back: back, frontId: window.windowId, backId: other.windowId, background: background, rect: rect)
        }
        focusWindowFromTabStrip(other.windowId, fallbackWorkspace: focus.workspace.name)
    }

    private func snapshot(_ id: UInt32) -> CGImage? {
        guard let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .nominalResolution]
        ) else { return nil }
        // Nominal resolution is one pixel per point. Trim the native one-point outline
        // so it does not become a bright edge when the snapshot rotates.
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard image.width > 2, image.height > 2 else { return image }
        return image.cropping(to: bounds.insetBy(dx: 1, dy: 1))
    }

    private func animate(front: CGImage, back: CGImage, frontId: UInt32, backId: UInt32, background: CGImage, rect: Rect) {
        let frame = CGRect(x: rect.topLeftX, y: mainMonitor.height - rect.topLeftY - rect.height,
                           width: rect.width, height: rect.height)
            .insetBy(dx: -backdropPadding, dy: -backdropPadding)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let root = CALayer()
        // Cover the real windows and their shadows throughout the rotation.
        root.contents = background
        root.contentsGravity = .resize
        view.layer = root
        panel.contentView = view
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / max(rect.width * 2, 1000)
        root.sublayerTransform = perspective
        var faces: [(windowId: UInt32, layer: CALayer, hiddenAngle: Double)] = []
        for (image, id, start, hidden) in [(front, frontId, 0.0, Double.pi), (back, backId, -Double.pi, -Double.pi)] {
            let face = CALayer()
            face.frame = view.bounds.insetBy(dx: backdropPadding, dy: backdropPadding)
            face.contents = image
            face.contentsGravity = .resize
            face.isDoubleSided = false
            face.allowsEdgeAntialiasing = true
            root.addSublayer(face)
            face.transform = CATransform3DMakeRotation(CGFloat(start), 0, 1, 0)
            faces.append((id, face, hidden))
        }
        animation = FlipAnimation(panel: panel, faces: faces)
        CATransaction.commit()
        _ = retargetAnimation(to: backId)
        panel.orderFrontRegardless()
    }

    /// Reverse from the displayed angles without taking another snapshot or
    /// waiting for the previous rotation. Reuse the overlay for the same pair.
    private func retargetAnimation(to windowId: UInt32) -> Bool {
        guard let animation, animation.faces.contains(where: { $0.windowId == windowId }) else { return false }
        completionTask?.cancel()
        let rotations = animation.faces.map { face in
            let from = (face.layer.presentation()?.value(forKeyPath: "transform.rotation.y") as? Double) ??
                (face.layer.animation(forKey: "flip") as? CABasicAnimation)?.fromValue as? Double ??
                (face.layer.value(forKeyPath: "transform.rotation.y") as? Double) ?? 0
            let to = face.windowId == windowId ? 0 : face.hiddenAngle
            return (layer: face.layer, from: from, to: to)
        }
        let distance = rotations.map { abs($0.to - $0.from) }.max() ?? Double.pi
        let duration = max(0.06, 0.32 * distance / Double.pi)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in rotations {
            item.layer.transform = CATransform3DMakeRotation(CGFloat(item.to), 0, 1, 0)
            let rotation = CABasicAnimation(keyPath: "transform.rotation.y")
            rotation.fromValue = item.from
            rotation.toValue = item.to
            rotation.duration = duration
            rotation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            item.layer.add(rotation, forKey: "flip")
        }
        CATransaction.commit()
        completionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            animation.panel.orderOut(nil)
            if self?.animation?.panel === animation.panel { self?.animation = nil }
        }
        return true
    }

    private func cancelAnimation() {
        completionTask?.cancel()
        completionTask = nil
        animation?.panel.orderOut(nil)
        animation = nil
    }
}
