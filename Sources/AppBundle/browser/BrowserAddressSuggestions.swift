import Foundation
import WorkspaceCore

struct BrowserAddressSuggestion: Equatable {
    enum Kind { case history, tab, search, address }
    let kind: Kind
    let title: String
    let url: String
    var tabID: SurfaceID? = nil
    var iconPNGBase64: String? = nil

    var displayURL: String { Self.displayURL(url) }

    static func displayURL(_ url: String) -> String {
        var result = url
        for prefix in ["https://", "http://"] where result.lowercased().hasPrefix(prefix) {
            result.removeFirst(prefix.count)
        }
        if result.hasSuffix("/"), URLComponents(string: url)?.path == "/" { result.removeLast() }
        return result
    }

    func completion(for query: String) -> String? {
        guard kind == .history || kind == .tab, !query.isEmpty,
              !query.contains(where: \.isWhitespace) else { return nil }
        let display = displayURL
        let candidates = [display.hasPrefix("www.") ? String(display.dropFirst(4)) : display, display, url]
        for candidate in candidates {
            if let range = candidate.range(of: query, options: [.anchored, .caseInsensitive]), range.upperBound < candidate.endIndex {
                return query + candidate[range.upperBound...]
            }
        }
        return nil
    }
}

enum BrowserAddressSuggestions {
    static func make(query: String, history: [BrowserHistoryEntry], tabs: [BrowserTabRecord],
                     surfaceID: SurfaceID, isPrivate: Bool, limit: Int = 8) -> [BrowserAddressSuggestion] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var entries: [String: (BrowserAddressSuggestion, Int, Double)] = [:]
        for entry in history where !isPrivate && entry.isValid {
            entries[entry.url] = (.init(kind: .history, title: entry.title, url: entry.url), entry.visitCount, entry.lastVisit)
        }
        for tab in tabs.sorted(by: { $0.surfaceID.description < $1.surfaceID.description })
            where tab.surfaceID.browserProfileID == surfaceID.browserProfileID && tab.privateBrowsing == isPrivate {
            guard BrowserHistoryEntry(url: tab.url, title: tab.title).isValid else { continue }
            let old = entries[tab.url]
            let otherTab = tab.surfaceID == surfaceID ? old?.0.tabID : tab.surfaceID
            entries[tab.url] = (.init(kind: old == nil ? .tab : old!.0.kind,
                title: tab.title.isEmpty ? old?.0.title ?? "" : tab.title, url: tab.url,
                tabID: otherTab, iconPNGBase64: tab.iconPNGBase64 ?? old?.0.iconPNGBase64), old?.1 ?? 0, old?.2 ?? 0)
        }
        func rank(_ item: BrowserAddressSuggestion) -> Int {
            guard !query.isEmpty else { return 0 }
            var host = URLComponents(string: item.url)?.host?.lowercased() ?? ""
            if host.hasPrefix("www.") { host.removeFirst(4) }
            if host == query.lowercased() { return 0 }
            if host.hasPrefix(query.lowercased()) { return 1 }
            if item.completion(for: query) != nil { return 2 }
            return item.displayURL.localizedCaseInsensitiveContains(query) ? 3 : 4
        }
        let matches = entries.values.filter { item, _, _ in
            let text = (item.title + " " + item.url).lowercased()
            return terms.allSatisfy { text.contains($0) }
        }.sorted { lhs, rhs in
            let left = rank(lhs.0), right = rank(rhs.0)
            if left != right { return left < right }
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
            return lhs.0.url < rhs.0.url
        }.map(\.0)
        guard !query.isEmpty else { return Array(matches.prefix(max(0, limit))) }
        guard let destination = browserNavigationURL(query) else { return [] }
        var search = URLComponents(string: "https://kagi.com/search")!
        search.queryItems = [.init(name: "q", value: query)]
        let searchRow = BrowserAddressSuggestion(kind: .search, title: query + " — Kagi Search", url: search.url!.absoluteString)
        // Only a prefix match becomes the default. A title/substring result must
        // never replace the user's search just because it happens to be first.
        var result: [BrowserAddressSuggestion] = []
        if let first = matches.first, first.completion(for: query) != nil || first.displayURL.lowercased() == query.lowercased() || first.url.lowercased() == query.lowercased() {
            result.append(first)
        } else if browserNavigationURL(query, allowSearch: false) != nil {
            result.append(.init(kind: .address, title: query, url: destination))
        }
        result.append(searchRow)
        result.append(contentsOf: matches.filter { match in !result.contains(where: { $0.url == match.url }) })
        return Array(result.prefix(max(0, limit)))
    }
}

extension BrowserWorkspaceController {
    func addressSuggestions(_ query: String, for id: SurfaceID,
                            completion: @escaping ([BrowserAddressSuggestion]) -> Void) {
        guard let session = owner(of: id), let current = session.inventory.tabs[id] else { completion([]); return }
        session.queryHistory(query, surfaceID: id) { [weak self, weak session] entries in
            guard let self, let session, self.owner(of: id) === session,
                  session.inventory.tabs[id] != nil else { completion([]); return }
            completion(BrowserAddressSuggestions.make(query: query, history: entries,
                tabs: Array(session.inventory.tabs.values), surfaceID: id, isPrivate: current.privateBrowsing))
        }
    }
}
