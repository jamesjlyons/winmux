import Foundation

public struct BrowserNewTabRequest: Equatable, Sendable {
    public let epoch: UUID
    public let operation: UUID
    public let sourceSurfaceID: SurfaceID?
    public let profileID: UUID?
    public let revision: UInt64
    public let url: String?
}
