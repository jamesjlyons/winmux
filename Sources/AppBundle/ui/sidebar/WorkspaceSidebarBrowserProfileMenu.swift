import AppKit
import SwiftUI

struct WorkspaceSidebarBrowserProfileMenu: View {
    let project: WorkspaceSidebarProjectViewModel

    private var selectedName: String {
        project.browserProfiles.first { $0.id == project.browserProfileID }?.name ?? (project.browserProfileID == nil ? "Shared" : "Unavailable")
    }

    var body: some View {
        Menu("Browser Profile: \(selectedName)") {
            choice("Shared", id: nil)
            ForEach(project.browserProfiles) { profile in
                choice(profile.name, id: profile.id)
            }
            Divider()
            Button("New Profile…") {
                // Wait for menu tracking to release keyboard focus.
                DispatchQueue.main.async { createProfile() }
            }
            Divider()
            Text("Used for new tabs. Existing tabs and pins keep their profile.")
        }
        .disabled(!project.supportsBrowserProfiles)
    }

    private func choice(_ name: String, id: UUID?) -> some View {
        Toggle(name, isOn: Binding(get: { project.browserProfileID == id }, set: { _ in
            do { try BrowserWorkspaceController.shared.setBrowserProfile(id, for: project.id) }
            catch { showWorkspaceSidebarError(error.localizedDescription) }
        }))
        .toggleStyle(.checkbox)
    }

    private func createProfile() {
        let alert = NSAlert()
        alert.messageText = "New Browser Profile"
        alert.informativeText = "Give this profile a name, such as Work or Personal. It has separate history, cookies, extensions, and saved passwords. You can use it in other Spaces too. Existing tabs and pins keep their profile."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Profile name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create Profile")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try BrowserWorkspaceController.shared.createBrowserProfile(named: field.stringValue, for: project.id) }
        catch { showWorkspaceSidebarError(error.localizedDescription) }
    }
}
