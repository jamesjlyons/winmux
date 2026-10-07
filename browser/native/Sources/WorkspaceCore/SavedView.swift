import Foundation

/// Saved intent is separate from an optional, replaceable runtime binding.
public enum ViewLaunchDescriptor: Codable, Equatable, Sendable {
    case browser(profileID: UUID, url: String)
    case application(bundleIdentifier: String, bundlePath: String)

    func accepts(_ surface: SurfaceID) -> Bool {
        switch (self, surface) {
        case (.browser(let expected, _), .browserTab(let actual, _)): expected == actual
        case (.application, .nativeWindow): true
        default: false
        }
    }

    var isValid: Bool {
        switch self {
        case .browser(_, let url): !url.isEmpty && url.utf8.count <= 16_384
        case .application(let bundle, let path):
            !bundle.isEmpty && bundle.utf8.count <= 1024 && path.utf8.count <= 16_384
        }
    }
}

public struct ViewMember: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public var launch: ViewLaunchDescriptor?
    public var surfaceID: SurfaceID?
    public var iconPNGBase64: String?

    public init(id: UUID = UUID(), title: String, launch: ViewLaunchDescriptor? = nil,
                surfaceID: SurfaceID? = nil, iconPNGBase64: String? = nil) {
        self.id = id; self.title = title; self.launch = launch
        self.surfaceID = surfaceID; self.iconPNGBase64 = iconPNGBase64
    }

    public var isValid: Bool {
        title.utf8.count <= 4096 && (iconPNGBase64?.utf8.count ?? 0) <= 131_072 &&
            (launch?.isValid ?? true) &&
            (surfaceID.map { launch?.accepts($0) ?? true } ?? true)
    }
}

/// Both regular and pinned Views use member identities for their saved layout.
/// A live layout is a projection; closing a binding never deletes a saved slot.
public struct SavedView: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case app, tab, group }
    public var id: UUID
    public var spaceID: String
    public var workspaceName: String
    public var title: String
    public var isPinned: Bool
    public var kind: Kind
    public var members: [ViewMember]
    public var layout: [ViewLayoutNode]
    public var selectedMember: UUID?
    public var formerRegularIndex: Int?

    public init(id: UUID = UUID(), spaceID: String, workspaceName: String, title: String,
                isPinned: Bool = false, kind: Kind = .group, members: [ViewMember] = [], layout: [ViewLayoutNode] = [],
                selectedMember: UUID? = nil, formerRegularIndex: Int? = nil) {
        self.id = id; self.spaceID = spaceID; self.workspaceName = workspaceName; self.title = title
        self.isPinned = isPinned; self.kind = kind; self.members = members; self.layout = layout
        self.selectedMember = selectedMember; self.formerRegularIndex = formerRegularIndex
    }

    public var memberIDs: [UUID] { members.map(\.id) }

    public var isValid: Bool {
        let ids = members.map(\.id), surfaces = members.compactMap(\.surfaceID)
        let layoutIDs = layout.flatMap(\.members)
        var groups = Set<UUID>()
        return !spaceID.isEmpty && spaceID.utf8.count <= 1024 &&
            !workspaceName.isEmpty && workspaceName.utf8.count <= 1024 && title.utf8.count <= 4096 &&
            members.count <= 10_000 && members.allSatisfy(\.isValid) &&
            Set(ids).count == ids.count && Set(surfaces).count == surfaces.count &&
            (!isPinned || (!members.isEmpty && members.allSatisfy { $0.launch != nil })) &&
            layout.allSatisfy { $0.validate(depth: 0, groups: &groups) } &&
            Set(layoutIDs).count == layoutIDs.count && Set(layoutIDs).isSubset(of: Set(ids)) &&
            (selectedMember.map { ids.contains($0) } ?? true) &&
            (formerRegularIndex.map { $0 >= 0 } ?? true)
    }

    public var bindings: [UUID: SurfaceID] {
        members.reduce(into: [:]) { result, member in result[member.id] = member.surfaceID }
    }

    /// Adapters supply validated owners. A profile mismatch or duplicate binding
    /// cannot partly change the saved View.
    @discardableResult public mutating func bind(_ memberID: UUID, to surface: SurfaceID?) -> Bool {
        guard let index = members.firstIndex(where: { $0.id == memberID }),
              surface.map({ id in
                  (members[index].launch?.accepts(id) ?? true) &&
                      !members.contains { $0.id != memberID && $0.surfaceID == id }
              }) ?? true else { return false }
        members[index].surfaceID = surface
        return true
    }

    /// Capture complete arrangements, or update metadata while retaining absent
    /// members and their proportions. This never launches or discovers owners.
    public mutating func captureLayout(from tree: SurfaceTree, selected: SurfaceID?) {
        let bindings = bindings
        let reverse = bindings.reduce(into: [SurfaceID: UUID]()) { $0[$1.value] = $1.key }
        if let selected = selected.flatMap({ reverse[$0] }) { selectedMember = selected }
        let nodes = tree.roots[workspaceName] ?? []
        let live = Set(nodes.flatMap(\.surfaces))
        let allSlotsPresent = layout.flatMap(\.members).allSatisfy { bindings[$0].map(live.contains) ?? false }
        if bindings.count == members.count && allSlotsPresent {
            layout = nodes.compactMap { ViewLayoutNode.capture($0, tree: tree, members: reverse) }
        } else {
            layout = layout.map { $0.refreshing(from: tree, bindings: bindings) }
        }
    }

    /// The caller identifies available tiled owners. Stored bindings alone do
    /// not establish availability and never trigger an application/page launch.
    public func liveLayout(available: Set<SurfaceID>) -> SurfaceTree {
        let live = bindings.filter { available.contains($0.value) }
        var tree = SurfaceTree()
        tree.reconcile(members.compactMap { live[$0.id] }, in: workspaceName)
        tree.restorePinnedLayout(layout, bindings: live, in: workspaceName)
        if let selected = selectedMember.flatMap({ live[$0] }) { tree.select(selected) }
        return tree
    }
}
