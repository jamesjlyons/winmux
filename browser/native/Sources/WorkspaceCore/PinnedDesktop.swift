import Foundation

/// Compatibility spelling for snapshots and callers migrating to shared Views.
public typealias PinnedLayoutNode = ViewLayoutNode

public struct PinnedDesktop: Codable, Equatable, Sendable, Identifiable {
    public typealias Kind = SavedView.Kind
    public var id: UUID
    public var spaceID: String
    public var workspaceName: String
    public var title: String
    public var kind: Kind
    public var memberIDs: [UUID]
    public var layout: [PinnedLayoutNode]
    public var selectedMember: UUID?
    public var formerRegularIndex: Int?

    public init(id: UUID = UUID(), spaceID: String, workspaceName: String, title: String,
                kind: Kind, memberIDs: [UUID], layout: [PinnedLayoutNode] = [],
                selectedMember: UUID? = nil, formerRegularIndex: Int? = nil) {
        self.id = id; self.spaceID = spaceID; self.workspaceName = workspaceName
        self.title = title; self.kind = kind; self.memberIDs = memberIDs; self.layout = layout
        self.selectedMember = selectedMember; self.formerRegularIndex = formerRegularIndex
    }

    public var isValid: Bool {
        var groups = Set<UUID>()
        guard layout.allSatisfy({ $0.validate(depth: 0, groups: &groups) }) else { return false }
        return (formerRegularIndex.map { $0 >= 0 } ?? true) && !spaceID.isEmpty && spaceID.utf8.count <= 1024 && !workspaceName.isEmpty && workspaceName.utf8.count <= 1024 &&
        title.utf8.count <= 4096 && !memberIDs.isEmpty && memberIDs.count <= 10000 &&
        Set(memberIDs).count == memberIDs.count &&
        Set(layout.flatMap(\.members)).isSubset(of: Set(memberIDs)) &&
        Set(layout.flatMap(\.members)).count == layout.flatMap(\.members).count &&
        (selectedMember.map(memberIDs.contains) ?? true)
    }
}

public struct SpacePinShelf: Codable, Equatable, Sendable {
    public var spaceID: String
    public var desktopOrder: [UUID]
    public var lastRegularWorkspaceName: String?
    public init(spaceID: String, desktopOrder: [UUID] = [], lastRegularWorkspaceName: String? = nil) {
        self.spaceID = spaceID; self.desktopOrder = desktopOrder; self.lastRegularWorkspaceName = lastRegularWorkspaceName
    }
}
