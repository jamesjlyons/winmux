import AppKit
import WorkspaceCore

extension BrowserWorkspaceController {
    func presentPrivacySettings(for id: SurfaceID) {
        guard let session = owner(of: id), session.supportsPrivacy,
              let saved = session.inventory.tabs[id]?.privacy else { return }
        let alert = NSAlert()
        alert.messageText = "Privacy Settings"
        alert.informativeText = "Search and cookie preferences apply to this browser profile. Background service changes take effect after restarting the browser."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let security = NSButton(checkboxWithTitle: "Allow security component updates", target: nil, action: nil)
        let extensions = NSButton(checkboxWithTitle: "Allow extension updates", target: nil, action: nil)
        let filters = NSButton(checkboxWithTitle: "Allow daily ad and tracker filter updates", target: nil, action: nil)
        let cookies = NSButton(checkboxWithTitle: "Block third-party cookies", target: nil, action: nil)
        for (button, enabled) in [(security, saved.securityUpdates), (extensions, saved.extensionUpdates),
                                  (filters, saved.filterUpdates), (cookies, saved.thirdPartyCookiesBlocked)] {
            button.state = enabled ? .on : .off
        }
        let search = NSTextField(string: saved.searchTemplate)
        search.setAccessibilityLabel("Search URL template")
        let label = NSTextField(wrappingLabelWithString: "Search URL — use {searchTerms} for your query")
        let exceptions = NSTextField(wrappingLabelWithString: "Manage cookie exceptions in browser Settings → Privacy and security → Third-party cookies.")
        let stack = NSStackView(views: [security, extensions, filters, cookies, label, search, exceptions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.frame = CGRect(x: 0, y: 0, width: 420, height: 240)
        search.widthAnchor.constraint(equalToConstant: 420).isActive = true
        exceptions.widthAnchor.constraint(equalToConstant: 420).isActive = true
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let settings = BrowserPrivacySettings(securityUpdates: security.state == .on, extensionUpdates: extensions.state == .on,
            filterUpdates: filters.state == .on, searchTemplate: search.stringValue,
            thirdPartyCookiesBlocked: cookies.state == .on)
        guard let data = try? JSONEncoder().encode(settings), let json = String(data: data, encoding: .utf8) else { return }
        _ = session.request(.privacy, surfaceID: id, url: json) { reply in
            if reply != .issued {
                BrowserToolbarController.shared.showFailure(for: id, message: "Settings could not be saved. Check the search URL and try again.")
            }
        }
    }
}
