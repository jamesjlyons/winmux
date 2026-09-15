import AppKit
import SwiftUI

enum WorkspaceSidebarSymbolSearchCommand {
    case move(Int)
    case select
    case cancel
}

struct WorkspaceSidebarSymbolSearchField: NSViewRepresentable {
    @Binding var text: String
    let onCommand: (WorkspaceSidebarSymbolSearchCommand) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = AutofocusingSymbolSearchField()
        field.placeholderString = "Search symbols"
        field.setAccessibilityLabel("Search symbols")
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.focusRingType = .exterior
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: WorkspaceSidebarSymbolSearchField
        init(_ parent: WorkspaceSidebarSymbolSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Leave composed text and modified cursor movement to the system editor.
            guard !textView.hasMarkedText() else { return false }
            let command: WorkspaceSidebarSymbolSearchCommand
            switch selector {
                case #selector(NSResponder.moveUp(_:)): command = .move(-7)
                case #selector(NSResponder.moveDown(_:)): command = .move(7)
                case #selector(NSResponder.moveLeft(_:)): command = .move(-1)
                case #selector(NSResponder.moveRight(_:)): command = .move(1)
                case #selector(NSResponder.insertNewline(_:)): command = .select
                case #selector(NSResponder.cancelOperation(_:)): command = .cancel
                default: return false
            }
            parent.onCommand(command)
            return true
        }
    }
}

private final class AutofocusingSymbolSearchField: NSSearchField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeKey()
            window.makeFirstResponder(self)
        }
    }
}
