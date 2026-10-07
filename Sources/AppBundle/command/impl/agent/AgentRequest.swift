import AppKit
import Common
import Foundation
import WorkspaceCore

// MARK: - Input

struct AgentRequest: Decodable {
    let schemaVersion: Int?
    let snapshotId: String?
    let worldId: String?
    let edit: AgentEdit?

    static func read(path: String) throws -> AgentRequest {
        let data = try Data(contentsOf: URL(filePath: path))
        return try JSONDecoder().decode(AgentRequest.self, from: data)
    }

    var operations: [AgentOperation] {
        (edit?.operations ?? []) + (edit?.actions ?? [])
    }

    @MainActor
    func validate() async throws -> [String] {
        var errors: [String] = []
        validateFreshWorldId(appendTo: &errors)
        guard errors.isEmpty else { return errors }
        var context = AgentValidationContext()
        for operation in operations {
            try await operation.validate(context: &context, appendTo: &errors)
        }
        if let layout = edit?.layout {
            try await layout.validate(context: &context, appendTo: &errors)
        }
        // Window matching and owner reads can suspend on the main actor.
        validateFreshWorldId(appendTo: &errors)
        return errors
    }

    @MainActor
    func validateFreshWorldId(appendTo errors: inout [String]) {
        if let worldId {
            let currentWorldId = currentAgentWorldId()
            if worldId != currentWorldId {
                errors.append("Agent JSON is stale: worldId '\(worldId)' does not match current worldId '\(currentWorldId)'. Run 'winmux agent query --path <path>' again before applying.")
            }
        } else if snapshotId != nil {
            errors.append("Agent JSON is missing worldId. Run 'winmux agent query --path <path>' again before applying.")
        }
    }

    @MainActor
    func apply() async throws {
        var freshnessErrors: [String] = []
        validateFreshWorldId(appendTo: &freshnessErrors)
        if !freshnessErrors.isEmpty { throw AgentEditError(freshnessErrors.joined(separator: "\n")) }
        var context = AgentApplyContext()
        for operation in operations {
            try await operation.apply(context: &context)
        }
        if let layout = edit?.layout {
            try await layout.apply()
        }
    }
}

struct AgentEdit: Decodable {
    let mode: String?
    let operations: [AgentOperation]?
    let actions: [AgentOperation]?
    let layout: AgentLayoutEdit?
}

@MainActor struct AgentValidationContext {
    var plannedTabGroups: [String: Set<UInt32>] = [:]
    var sharedTree: SurfaceTree? = BrowserWorkspaceController.shared.usesSurfaceTree ? BrowserWorkspaceController.shared.surfaceTree : nil
    var sharedGroupAliases: [String: UUID] = [:]
    var floatingWindows: Set<SurfaceID> = Set(Workspace.all.flatMap { $0.floatingWindows.map(\.surfaceID) })

    mutating func accept(_ plan: AgentSharedPaneEdit) {
        sharedTree = plan.resultingTree
        sharedGroupAliases.merge(plan.aliases) { _, new in new }
        floatingWindows.subtract(plan.admittedFloating)
        floatingWindows.formUnion(plan.floating)
    }
}

struct AgentApplyContext {
    var tabGroupAliases: [String: TilingContainer] = [:]
    var sharedGroupAliases: [String: UUID] = [:]
}

struct AgentEditError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct AgentLayoutEdit: Codable {
    let workspaces: [AgentWorkspaceLayout]

    @MainActor
    func validate(appendTo errors: inout [String]) async throws {
        var context = AgentValidationContext()
        try await validate(context: &context, appendTo: &errors)
    }

    @MainActor
    func validate(context: inout AgentValidationContext, appendTo errors: inout [String]) async throws {
        var mentioned: Set<SurfaceID> = []
        for workspace in workspaces {
            if let tree = context.sharedTree {
                do {
                    let plan = try workspace.sharedLayout(in: tree, floatingWindows: context.floatingWindows)
                    if !mentioned.isDisjoint(with: plan.mentioned) { errors.append("A surface appears in more than one requested View layout") }
                    mentioned.formUnion(plan.mentioned)
                    context.accept(plan)
                } catch let error as AgentEditError { errors.append(error.message) }
            } else { try await workspace.validate(appendTo: &errors) }
        }
    }

    @MainActor
    func apply() async throws {
        for workspace in workspaces {
            try await workspace.apply()
        }
    }
}
