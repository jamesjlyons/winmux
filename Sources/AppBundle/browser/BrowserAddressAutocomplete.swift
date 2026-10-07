import AppKit
import WorkspaceCore

/// Keeps the field editor in the toolbar while a non-key child panel shows
/// completions over the page. Responses are fenced to the current editing draft.
@MainActor
final class BrowserAddressAutocomplete {
    typealias Provider = (String, @escaping ([BrowserAddressSuggestion]) -> Void) -> Void
    var provider: Provider?
    var onNavigate: ((String) -> Void)?
    var onSwitchTab: ((SurfaceID) -> Void)?
    private weak var field: NSTextField?
    private var popup: BrowserAddressSuggestionsPanel?
    private var pending: Task<Void, Never>?
    private var generation = UUID()
    private var query = ""
    private var suppressCompletion = false
    private var applyingCompletion = false
    private(set) var suggestions: [BrowserAddressSuggestion] = []
    private(set) var selectedIndex = -1
    var isVisible: Bool { popup?.isVisible == true }

    init(field: NSTextField) { self.field = field }

    func beginEditing() {
        query = ""
        request(query: "", editor: field?.currentEditor() as? NSTextView, allowInline: false)
    }

    func textChanged() {
        guard !applyingCompletion else { return }
        guard let editor = field?.currentEditor() as? NSTextView else { return }
        guard !editor.hasMarkedText() else { dismiss(); return }
        let value = editor.string
        let atEnd = editor.selectedRange() == NSRange(location: value.utf16.count, length: 0)
        let canComplete = !suppressCompletion && atEnd && value.utf16.count > query.utf16.count &&
            NSApp.currentEvent?.modifierFlags.contains(.command) != true
        suppressCompletion = false
        request(query: value, editor: editor, allowInline: canComplete)
    }

    func request(query: String, editor: NSTextView?, allowInline: Bool) {
        pending?.cancel()
        generation = UUID()
        let token = generation
        self.query = query
        suggestions = []
        selectedIndex = -1
        popup?.dismiss()
        guard query.utf8.count <= 2048 else { return }
        pending = Task { @MainActor [weak self, weak editor] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self, self.generation == token, let provider = self.provider else { return }
            provider(query) { [weak self, weak editor] suggestions in
                guard let self, self.generation == token, let editor, !editor.hasMarkedText() else { return }
                self.suggestions = suggestions
                if !query.isEmpty {
                    self.selectedIndex = allowInline ? (suggestions.isEmpty ? -1 : 0)
                        : suggestions.firstIndex(where: { $0.kind == .search || $0.kind == .address }) ?? -1
                }
                if allowInline, let first = suggestions.first,
                   editor.string == query, editor.selectedRange() == NSRange(location: query.utf16.count, length: 0),
                   let completed = first.completion(for: query) {
                    // Register the inserted suffix with the editor so undo never
                    // leaves a fragment appended to an earlier address draft.
                    self.applyingCompletion = true
                    editor.breakUndoCoalescing()
                    editor.insertText(String(completed.dropFirst(query.count)),
                        replacementRange: NSRange(location: query.utf16.count, length: 0))
                    editor.breakUndoCoalescing()
                    editor.setSelectedRange(NSRange(location: query.utf16.count, length: completed.utf16.count - query.utf16.count))
                    self.applyingCompletion = false
                }
                self.show()
            }
        }
    }

    func dismiss() {
        pending?.cancel()
        pending = nil
        generation = UUID()
        suggestions = []
        selectedIndex = -1
        popup?.dismiss()
    }

    func command(_ selector: Selector, editor: NSTextView) -> Bool {
        guard !editor.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)):
            suppressCompletion = true
            return false
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !suggestions.isEmpty else {
                request(query: editor.string, editor: editor, allowInline: false)
                return true
            }
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            selectedIndex = min(suggestions.count - 1, max(-1, selectedIndex + delta))
            let value = selectedIndex < 0 ? query : suggestions[selectedIndex].kind == .search
                ? query : suggestions[selectedIndex].displayURL
            replaceText(value, in: editor, selection: NSRange(location: value.utf16.count, length: 0))
            show()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            guard suggestions.indices.contains(selectedIndex) else { dismiss(); return false }
            activate(selectedIndex)
            return true
        case #selector(NSResponder.insertTab(_:)):
            guard suggestions.indices.contains(selectedIndex), let id = suggestions[selectedIndex].tabID else { return false }
            dismiss()
            onSwitchTab?(id)
            return true
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)):
            if editor.selectedRange().length > 0, editor.selectedRange().upperBound == editor.string.utf16.count {
                query = editor.string
                editor.setSelectedRange(NSRange(location: query.utf16.count, length: 0))
                return true
            }
            return false
        default: return false
        }
    }

    private func replaceText(_ value: String, in editor: NSTextView, selection: NSRange) {
        editor.string = value
        field?.stringValue = value
        editor.setSelectedRange(selection)
    }

    func activate(_ index: Int, switchTab: Bool = false) {
        guard suggestions.indices.contains(index) else { return }
        let suggestion = suggestions[index]
        dismiss()
        if switchTab, let id = suggestion.tabID { onSwitchTab?(id) }
        else { onNavigate?(suggestion.url) }
    }

    func reposition() {
        guard isVisible, let field else { return }
        popup?.position(below: field)
    }

    private func show() {
        guard !suggestions.isEmpty, let field, let parent = field.window, parent.isVisible else { return }
        let popup = self.popup ?? BrowserAddressSuggestionsPanel()
        self.popup = popup
        popup.appearance = parent.appearance
        popup.update(suggestions, selectedIndex: selectedIndex) { [weak self] index, switchTab in
            self?.activate(index, switchTab: switchTab)
        }
        if popup.parent !== parent {
            popup.parent?.removeChildWindow(popup)
            parent.addChildWindow(popup, ordered: .above)
        }
        popup.position(below: field)
        popup.orderFront(nil)
    }
}

@MainActor
private final class BrowserAddressSuggestionsPanel: NSPanel {
    private let list = NSView()
    private var rows: [BrowserAddressSuggestionRow] = []
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        list.wantsLayer = true
        list.layer?.cornerRadius = 12
        list.layer?.masksToBounds = true
        contentView = list
        setAccessibilityLabel("Address suggestions")
        setAccessibilityIdentifier("winmux.browser.address.suggestions")
    }

    func update(_ suggestions: [BrowserAddressSuggestion], selectedIndex: Int,
                activate: @escaping (Int, Bool) -> Void) {
        rows.forEach { $0.removeFromSuperview() }
        rows = suggestions.enumerated().map { index, item in
            let row = BrowserAddressSuggestionRow(item: item, selected: index == selectedIndex) { activate(index, $0) }
            list.addSubview(row)
            return row
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            list.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            list.layer?.borderColor = NSColor.separatorColor.cgColor
            list.layer?.borderWidth = 0.5
        }
    }

    func position(below field: NSView) {
        guard let parent = field.window else { return }
        let anchor = parent.convertToScreen(field.convert(field.bounds, to: nil))
        let visible = parent.screen?.visibleFrame ?? parent.frame
        let width = min(max(anchor.width + 12, 320), visible.width - 16)
        let height = CGFloat(rows.count) * 34 + 12
        let x = max(visible.minX + 8, min(anchor.minX - 6, visible.maxX - width - 8))
        let below = anchor.minY - height - 7
        let y = below >= visible.minY ? below : min(anchor.maxY + 7, visible.maxY - height)
        setFrame(.init(x: x, y: y, width: width, height: height), display: true)
        for (index, row) in rows.enumerated() {
            row.frame = .init(x: 6, y: height - 6 - CGFloat(index + 1) * 34, width: width - 12, height: 34)
        }
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

@MainActor
private final class BrowserAddressSuggestionRow: NSView {
    private let main = BrowserAddressSuggestionButton()
    private let switchButton = BrowserAddressSuggestionButton()
    private let activate: (Bool) -> Void
    private let selected: Bool

    init(item: BrowserAddressSuggestion, selected: Bool, activate: @escaping (Bool) -> Void) {
        self.activate = activate
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        updateAppearance()
        main.isBordered = false
        main.alignment = .left
        main.font = .systemFont(ofSize: 13)
        main.lineBreakMode = .byTruncatingTail
        let title = item.title.isEmpty ? item.displayURL : item.title
        let label = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        if item.kind != .search, title != item.displayURL {
            label.append(NSAttributedString(string: "  —  " + item.displayURL,
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        main.attributedTitle = label
        let symbol = item.kind == .search ? "magnifyingglass" : item.kind == .history ? "clock.arrow.circlepath" : "globe"
        main.image = item.iconPNGBase64.flatMap { WorkspaceSidebarFaviconCache.shared.image(for: $0) }
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        main.imagePosition = .imageLeading
        main.imageScaling = .scaleProportionallyDown
        main.contentTintColor = .secondaryLabelColor
        main.target = self
        main.action = #selector(open)
        main.toolTip = item.kind == .search ? title : title + "\n" + item.url
        main.setAccessibilityLabel(main.toolTip)
        main.setAccessibilityIdentifier("winmux.browser.address.suggestion")
        main.setAccessibilityValue(selected ? "Selected" : "")
        addSubview(main)
        switchButton.title = "Switch to this tab"
        switchButton.font = .systemFont(ofSize: 11)
        switchButton.bezelStyle = .roundRect
        switchButton.controlSize = .small
        switchButton.target = self
        switchButton.action = #selector(switchTab)
        switchButton.isHidden = item.tabID == nil
        switchButton.toolTip = "Switch to this tab (Tab)"
        switchButton.setAccessibilityLabel("Switch to tab: " + title)
        addSubview(switchButton)
    }

    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }
    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = selected ? NSColor.labelColor.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
        }
    }
    override func layout() {
        super.layout()
        let switchWidth: CGFloat = switchButton.isHidden ? 0 : 124
        main.frame = .init(x: 8, y: 2, width: max(0, bounds.width - 16 - switchWidth), height: max(0, bounds.height - 4))
        switchButton.frame = .init(x: max(0, bounds.width - 124), y: 5, width: 118, height: 24)
    }
    @objc private func open() { activate(false) }
    @objc private func switchTab() { activate(true) }
}

private final class BrowserAddressSuggestionButton: NSButton {
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
