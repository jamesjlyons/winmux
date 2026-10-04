import Foundation

/// Keep this root preference explicit: an empty string survives a settings
/// clear and prevents an absent binding from re-enabling the default on restart.
func updateBrowserNewTabShortcutConfig(in text: String, notation: String) -> String {
    let key = "browser-new-tab-shortcut"
    let assignment = "\(key) = '\(notation)'"
    var lines = text.components(separatedBy: "\n")
    let rootEnd = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
    if let index = lines[..<rootEnd].firstIndex(where: { line in
        line.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == key
    }) { lines[index] = assignment }
    else { lines.insert(assignment, at: rootEnd) }
    return lines.joined(separator: "\n")
}
