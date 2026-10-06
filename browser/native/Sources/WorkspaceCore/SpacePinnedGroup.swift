import Foundation

/// One real layout group per space; ordering includes both browser and app pins.
public struct SpacePinnedGroup: Codable, Equatable, Sendable {
    public var spaceID: String
    public var workspaceName: String
    public var lastRegularWorkspaceName: String?
    public var pinOrder: [UUID]
    public var views: [PinnedViewGroup] = []
    public init(spaceID: String, workspaceName: String, lastRegularWorkspaceName: String? = nil, pinOrder: [UUID] = []) {
        self.spaceID = spaceID; self.workspaceName = workspaceName
        self.lastRegularWorkspaceName = lastRegularWorkspaceName; self.pinOrder = pinOrder
    }
    private enum CodingKeys: String, CodingKey { case spaceID, workspaceName, lastRegularWorkspaceName, pinOrder, views }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(spaceID: try c.decode(String.self, forKey: .spaceID), workspaceName: try c.decode(String.self, forKey: .workspaceName),
                  lastRegularWorkspaceName: try c.decodeIfPresent(String.self, forKey: .lastRegularWorkspaceName),
                  pinOrder: try c.decode([UUID].self, forKey: .pinOrder))
        views = try c.decodeIfPresent([PinnedViewGroup].self, forKey: .views) ?? []
    }
    public var isValid: Bool {
        views.count <= 5000 && views.allSatisfy { $0.isValid(in: workspaceName) } &&
        Set(views.map(\.id)).count == views.count &&
        Set(views.flatMap { $0.members.values }).count == views.flatMap { $0.members.values }.count &&
        Set(views.flatMap { $0.members.values }).isSubset(of: Set(pinOrder)) &&
        !spaceID.isEmpty && spaceID.utf8.count <= 1024 && !workspaceName.isEmpty && workspaceName.utf8.count <= 1024 &&
        pinOrder.count <= 10000 && Set(pinOrder).count == pinOrder.count
    }
}

public struct NativeAppSidebarPin: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var workspaceName: String
    public let bundleIdentifier: String
    public let bundlePath: String
    public let title: String
    public var surfaceID: SurfaceID?
    public init(id: UUID = UUID(), workspaceName: String, bundleIdentifier: String, bundlePath: String, title: String, surfaceID: SurfaceID? = nil) {
        self.id = id; self.workspaceName = workspaceName; self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath; self.title = title; self.surfaceID = surfaceID
    }
    public var isValid: Bool {
        !workspaceName.isEmpty && workspaceName.utf8.count <= 1024 && !bundleIdentifier.isEmpty && bundleIdentifier.utf8.count <= 1024 &&
        bundlePath.utf8.count <= 16384 && title.utf8.count <= 4096 &&
        (surfaceID.map { if case .nativeWindow = $0 { return true }; return false } ?? true)
    }
}
