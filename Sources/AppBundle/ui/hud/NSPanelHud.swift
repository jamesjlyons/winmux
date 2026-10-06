import AppKit

open class NSPanelHud: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        configureHUD()
    }

    init(styleMask: NSWindow.StyleMask) {
        super.init(
            contentRect: .zero,
            styleMask: styleMask,
            backing: .buffered,
            defer: false,
        )
        configureHUD()
    }

    private func configureHUD() {
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = false
        self.alphaValue = 1
        self.hasShadow = true
        self.isOpaque = false
        self.backgroundColor = .clear
    }
}
