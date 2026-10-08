import Foundation

/// Shared by Settings and commands so success means the saved value is live.
@MainActor
func saveSettingsConfig(
    section: String?, key: String, renderedValue: String,
    model: ShortcutSettingsModel = .shared,
) async throws {
    let url = preferredEditableConfigUrl()
    try writeSettingsConfig(to: url, section: section, key: key, renderedValue: renderedValue)
    guard try await reloadConfig(forceConfigUrl: url) else {
        throw NSError(domain: "WinMux", code: 1, userInfo: [NSLocalizedDescriptionKey: "Saved the setting, but could not reload the config."])
    }
    model.errorMessage = nil
    model.reload()
    WorkspaceSidebarPanel.refreshAll()
}

@MainActor
func writeSettingsConfig(to url: URL, section: String?, key: String, renderedValue: String) throws {
    let current: String
    if FileManager.default.fileExists(atPath: url.path) {
        current = try String(contentsOf: url, encoding: .utf8)
    } else {
        current = starterConfigText()
    }
    let updated = updateSettingsScalarConfig(in: current, section: section, key: key, renderedValue: renderedValue)
    let parsed = parseConfig(updated)
    guard parsed.errors.isEmpty else {
        throw NSError(domain: "WinMux", code: 1, userInfo: [NSLocalizedDescriptionKey: parsed.errors.map(\.description).joined(separator: "\n")])
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try updated.write(to: url, atomically: true, encoding: .utf8)
}
