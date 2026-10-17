import SwiftUI

private struct WorkspaceSidebarSearchQueryKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var workspaceSidebarSearchQuery: String {
        get { self[WorkspaceSidebarSearchQueryKey.self] }
        set { self[WorkspaceSidebarSearchQueryKey.self] = newValue }
    }
}

struct WorkspaceSidebarSearchTitle: View {
    let title: String
    @Environment(\.workspaceSidebarSearchQuery) private var query

    var body: some View {
        Text(highlightedTitle)
    }

    private var highlightedTitle: AttributedString {
        var result = AttributedString(title)
        for range in workspaceSidebarSearchMatchRanges(in: title, query: query) {
            if let start = AttributedString.Index(range.lowerBound, within: result),
               let end = AttributedString.Index(range.upperBound, within: result) {
                result[start..<end].foregroundColor = .accentColor
                result[start..<end].inlinePresentationIntent = .stronglyEmphasized
            }
        }
        return result
    }
}
