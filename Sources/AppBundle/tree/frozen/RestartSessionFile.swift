import Common
import CryptoKit
import Foundation

struct RestartSessionFile: Sendable {
    let url: URL
    var backupURL: URL { url.appendingPathExtension("backup") }

    static func location(appSupport: URL, appName: String, explicitConfigPath: String?) -> URL {
        var directory = appSupport.appendingPathComponent(appName, isDirectory: true)
        if let explicitConfigPath {
            let path = URL(filePath: explicitConfigPath).standardizedFileURL.resolvingSymlinksInPath().path
            let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
            directory = directory.appendingPathComponent("sessions/\(hash)", isDirectory: true)
        }
        return directory.appendingPathComponent("window-state.json")
    }

    func read() throws -> RestartSessionSnapshot? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) || fm.fileExists(atPath: backupURL.path) else { return nil }
        do {
            return try decode(Data(contentsOf: url), source: url)
        } catch {
            // A newer version belongs to a newer build. Never replace it with an older backup.
            if case RestartSessionFileError.unsupportedVersion = error { throw error }
            guard fm.fileExists(atPath: backupURL.path) else { throw error }
            return try decode(Data(contentsOf: backupURL), source: backupURL)
        }
    }

    func write(_ snapshot: RestartSessionSnapshot) throws {
        let data = try JSONEncoder.winMuxDefault.encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let previous = try? Data(contentsOf: url), (try? decode(previous, source: url)) != nil {
            try previous.write(to: backupURL, options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }

    private func decode(_ data: Data, source: URL) throws -> RestartSessionSnapshot {
        struct Header: Decodable { let version: Int }
        let decoder = JSONDecoder()
        let version = try decoder.decode(Header.self, from: data).version
        switch version {
            case 1:
                struct Legacy: Decodable { let world: FrozenWorld }
                let legacy = try decoder.decode(Legacy.self, from: data)
                let modified = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date ?? .distantPast
                guard modified >= Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime) else {
                    throw RestartSessionFileError.previousBoot
                }
                return RestartSessionSnapshot(version: 1, savedAt: modified, bootSession: currentBootSession(), world: legacy.world,
                                              windows: nil, projects: nil, focusedWindowId: nil, focusedWorkspace: nil)
            case 2:
                let snapshot = try decoder.decode(RestartSessionSnapshot.self, from: data)
                guard snapshot.bootSession == currentBootSession() else { throw RestartSessionFileError.previousBoot }
                return snapshot
            default: throw RestartSessionFileError.unsupportedVersion(version)
        }
    }
}

enum RestartSessionFileError: LocalizedError {
    case unsupportedVersion(Int)
    case previousBoot

    var errorDescription: String? {
        switch self {
            case .unsupportedVersion(let version): "Session version \(version) requires a newer WinMux build."
            case .previousBoot: "The saved windows belong to a previous macOS session."
        }
    }
}
