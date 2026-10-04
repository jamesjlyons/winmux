import AppKit
import Common
import Foundation
import MASShortcut

extension ShortcutSettingsModel {
    var managedCommands: Set<String> {
        Set(actionsById.values.map(\.canonicalCommand)).union(workspaceManagedCommands)
    }

    func bindingNotation(for actionId: String) -> String? {
        assignments[actionId]
    }

    func shortcutValue(for actionId: String) -> MASShortcut? {
        guard let notation = bindingNotation(for: actionId) else { return nil }
        return masShortcut(from: notation)
    }

    func setShortcutValue(_ shortcut: MASShortcut?, for actionId: String) {
        errorMessage = nil
        if let shortcut, let notation = notation(from: shortcut) {
            applyBindingNotation(notation, to: actionId)
        } else {
            clearBinding(for: actionId)
        }
    }

    func clearBinding(for actionId: String) {
        errorMessage = nil
        var updatedAssignments = assignments
        updatedAssignments[actionId] = nil
        persistBindings(updatedAssignments, browserShortcutEdit: actionId == "browser-new-tab")
    }

    func applyBindingNotation(_ notation: String, to actionId: String) {
        if let conflict = customCommandConflict(for: notation, excluding: actionId) {
            errorMessage = "'\(notation)' is already used by custom binding: \(conflict)"
            reload()
            return
        }

        var updatedAssignments = assignments
        for (otherActionId, otherNotation) in assignments where otherActionId != actionId && otherNotation == notation {
            updatedAssignments[otherActionId] = nil
        }
        updatedAssignments[actionId] = notation
        persistBindings(updatedAssignments, browserShortcutEdit: actionId == "browser-new-tab")
    }

    func bindingConfigEdits(
        for updatedAssignments: [String: String],
        previousAssignments: [String: String],
        browserShortcutEdit: Bool,
    ) throws -> (assignments: [String: String], managedCommands: Set<String>) {
        var scope = managedCommands
        if browserShortcutEdit {
            let changedActions = Set(previousAssignments.keys).union(updatedAssignments.keys)
                .filter { previousAssignments[$0] != updatedAssignments[$0] }
            scope = Set(changedActions.compactMap { actionsById[$0]?.canonicalCommand })
            scope.insert("browser-new-tab")
        }
        let rendered = try renderedManagedAssignments(from: updatedAssignments, includeWorkspaceBindings: !browserShortcutEdit)
        return (rendered.filter { $0.value != "browser-new-tab" && scope.contains($0.value) }, scope)
    }

    func persistBindings(_ updatedAssignments: [String: String], browserShortcutEdit: Bool = false) {
        let previousAssignments = assignments
        assignments = updatedAssignments
        Task { @MainActor in
            do {
                let edits = try bindingConfigEdits(for: updatedAssignments, previousAssignments: previousAssignments,
                                                  browserShortcutEdit: browserShortcutEdit)
                let targetUrl = try persistMainModeBindings(
                    assignments: edits.assignments,
                    managedCommands: edits.managedCommands,
                    browserNewTabShortcut: updatedAssignments["browser-new-tab"] ?? "",
                )
                let isOk = try await reloadConfig(forceConfigUrl: targetUrl)
                if isOk {
                    reload()
                }
            } catch {
                errorMessage = error.localizedDescription
                reload()
            }
        }
    }

    func customCommandConflict(for notation: String, excluding actionId: String) -> String? {
        guard let binding = config.modes[mainModeId]?.bindings.values.first(where: { $0.descriptionWithKeyNotation == notation }) else {
            return nil
        }
        let command = binding.commands.prettyDescription
        guard let boundActionId = actionIdByCommand[command] else {
            return command
        }
        return boundActionId == actionId ? nil : nil
    }
}
