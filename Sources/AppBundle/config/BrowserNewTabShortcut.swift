import AppKit
import Common

@MainActor
func browserNewTabBinding(in configuration: Config) -> HotkeyBinding? {
    guard !configuration.browserNewTabShortcut.isEmpty else { return nil }
    var errors: [TomlParseError] = []
    guard let (modifiers, key) = parseBinding(configuration.browserNewTabShortcut, .rootKey("browser-new-tab-shortcut"), configuration.keyMapping.resolve()).getOrNil(appendErrorTo: &errors) else { return nil }
    let binding = HotkeyBinding(modifiers, key, [BrowserNewTabCommand(args: .init(rawArgs: []))],
                               descriptionWithKeyNotation: configuration.browserNewTabShortcut)
    let explicit = configuration.modes[mainModeId]?.bindings.values ?? Dictionary<String, HotkeyBinding>().values
    guard !explicit.contains(where: { $0.descriptionWithKeyCode == binding.descriptionWithKeyCode ||
        $0.commands.contains(where: { $0 is BrowserNewTabCommand }) }) else { return nil }
    return binding
}

@MainActor
func effectiveHotkeyBindings(for mode: String?, includesBrowserShortcut: Bool? = nil) -> [String: HotkeyBinding] {
    var bindings = mode.flatMap { config.modes[$0]?.bindings } ?? [:]
    let includeBrowser = includesBrowserShortcut ?? (BrowserNativeManagement.lease != nil)
    if includeBrowser, mode == mainModeId, let fallback = browserNewTabBinding(in: config) { bindings[fallback.descriptionWithKeyCode] = fallback }
    return bindings
}
