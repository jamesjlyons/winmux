import Foundation

struct RestartSessionWriteResult: Sendable {
    let snapshot: RestartSessionSnapshot
    let didWrite: Bool
}

/// Serializes disk access away from the main actor. Revisions are assigned when the live
/// tree is captured, so a delayed checkpoint cannot overwrite the final quit snapshot.
actor RestartSessionWriter {
    private var latestRevision: UInt64 = 0
    private var previousSnapshot: RestartSessionSnapshot?
    private var previousURL: URL?
    private let writeFile: @Sendable (RestartSessionSnapshot, RestartSessionFile) throws -> Void

    init(writeFile: @escaping @Sendable (RestartSessionSnapshot, RestartSessionFile) throws -> Void = { snapshot, file in
        try file.write(snapshot)
    }) {
        self.writeFile = writeFile
    }

    @discardableResult
    func write(_ snapshot: RestartSessionSnapshot, to file: RestartSessionFile, revision: UInt64) throws -> RestartSessionWriteResult? {
        guard revision >= latestRevision else { return nil }
        latestRevision = revision
        if previousURL == file.url, let previousSnapshot, snapshot.hasSameContent(as: previousSnapshot) {
            return RestartSessionWriteResult(snapshot: previousSnapshot, didWrite: false)
        }
        let interval = signposter.beginInterval("Session file write")
        defer { signposter.endInterval("Session file write", interval) }
        try writeFile(snapshot, file)
        previousSnapshot = snapshot
        previousURL = file.url
        return RestartSessionWriteResult(snapshot: snapshot, didWrite: true)
    }
}
