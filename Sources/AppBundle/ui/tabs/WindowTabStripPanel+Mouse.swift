import AppKit
import SwiftUI

extension WindowTabStripPanel {
    func shouldUpdate(content: WindowTabGroupChromeContent, strip: WindowTabStripViewModel) -> Bool {
        let frameChanged = currentPanelFrame != strip.frame
        if currentContent == content, !frameChanged, isVisible {
            updateMousePolicy()
            return false
        }
        return true
    }

    func updateMousePolicy(at screenPoint: CGPoint = NSEvent.mouseLocation) {
        let ignoresForMouseManipulation = currentlyManipulatedWithMouseWindowId != nil &&
            shouldIgnoreWindowTabStripMouseEventsDuringDrag(detachOrigin: getCurrentMouseTabDetachOrigin())
        // A floating window can cover only part of the strip. Passing through the
        // whole panel makes exposed tabs click the desktop underneath instead.
        let pointerIsOccluded = currentPanelFrame?.contains(screenPoint) == true &&
            currentContent?.occludingFloatingWindowFrames.contains(where: { $0.contains(screenPoint) }) == true
        let shouldIgnoreMouseEvents = externallyIgnoresMouseEvents ||
            ignoresForMouseManipulation ||
            pointerIsOccluded
        if ignoresMouseEvents != shouldIgnoreMouseEvents {
            ignoresMouseEvents = shouldIgnoreMouseEvents
        }
    }
}

final class WindowTabStripHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
