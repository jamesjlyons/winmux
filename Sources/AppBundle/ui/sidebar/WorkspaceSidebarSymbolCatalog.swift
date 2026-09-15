import Foundation

struct WorkspaceSidebarSymbolCatalog: Decodable, Sendable {
    struct Entry: Decodable, Equatable, Sendable, Identifiable {
        let name: String
        let keywords: [String]
        let macOS: String
        var id: String { name }

        func isAvailable(on version: String) -> Bool {
            macOS.compare(version, options: .numeric) != .orderedDescending
        }
    }

    let version: String
    let symbols: [Entry]

    static let bundled: WorkspaceSidebarSymbolCatalog = {
        guard let url = Bundle.module.url(forResource: "sf-symbols", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Self.self, from: data)
        else { preconditionFailure("Missing or invalid bundled SF Symbols catalog") }
        return catalog
    }()

    static func search(_ query: String, in entries: [Entry]) -> [Entry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return entries }
        let tokens = query.split(whereSeparator: { $0.isWhitespace || $0 == "." }).map(String.init)
        return entries.compactMap { entry -> (Entry, Int)? in
            if entry.name == query { return (entry, 0) }
            if entry.name.hasPrefix(query) { return (entry, 1) }
            if tokens.allSatisfy({ entry.name.contains($0) }) { return (entry, 2) }
            let searchable = ([entry.name] + entry.keywords).joined(separator: " ").lowercased()
            return tokens.allSatisfy { searchable.contains($0) } ? (entry, 3) : nil
        }
        .sorted { $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 < $1.1 }
        .map(\.0)
    }
}

@MainActor
final class WorkspaceSidebarAvailableSymbols {
    static let shared = WorkspaceSidebarAvailableSymbols()
    private var loading: Task<[WorkspaceSidebarSymbolCatalog.Entry], Never>?

    static func search(_ query: String, in entries: [WorkspaceSidebarSymbolCatalog.Entry]) -> [WorkspaceSidebarSymbolCatalog.Entry] {
        var results = WorkspaceSidebarSymbolCatalog.search(query, in: entries)
        let exact = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Exact-name lookup also covers OS symbols introduced after this catalog was bundled.
        if !exact.isEmpty, !results.contains(where: { $0.name == exact }),
           WorkspaceSidebarSymbolImages.image(named: exact) != nil
        {
            results.insert(.init(name: exact, keywords: [], macOS: "0"), at: 0)
        }
        return results
    }

    func entries() async -> [WorkspaceSidebarSymbolCatalog.Entry] {
        if let loading { return await loading.value }
        let task = Task { @MainActor in
            let version = ProcessInfo.processInfo.operatingSystemVersion
            let versionString = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            var result: [WorkspaceSidebarSymbolCatalog.Entry] = []
            for (index, entry) in WorkspaceSidebarSymbolCatalog.bundled.symbols.enumerated() {
                if entry.isAvailable(on: versionString), WorkspaceSidebarSymbolImages.image(named: entry.name) != nil {
                    result.append(entry)
                }
                // Let first-open typing, layout and drawing run while resolving the catalog.
                if index.isMultiple(of: 64) { await Task.yield() }
            }
            return result
        }
        loading = task
        return await task.value
    }
}
