import AppKit
import SwiftUI

/// Lets the pager's own scroll view handle overflow instead of switching projects.
struct WorkspaceSidebarProjectScrollRegion: NSViewRepresentable {
    @MainActor private static let views = NSHashTable<NSView>.weakObjects()

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Self.views.add(view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    @MainActor
    static func contains(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        return views.allObjects.contains { view in
            view.window === window && !view.isHiddenOrHasHiddenAncestor &&
                view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }
    }
}
