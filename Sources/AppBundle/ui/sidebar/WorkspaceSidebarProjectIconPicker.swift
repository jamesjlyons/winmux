import AppKit
import SwiftUI

struct WorkspaceSidebarProjectIconPicker: View {
    let project: WorkspaceSidebarProjectViewModel
    let onSelect: (String?) -> Void
    let onCancel: () -> Void
    @State private var query = ""
    @State private var entries: [WorkspaceSidebarSymbolCatalog.Entry] = []
    @State private var results: [WorkspaceSidebarSymbolCatalog.Entry] = []
    @State private var highlightedName: String?
    @State private var isLoading = true
    private let columns = 7

    private var color: Color {
        workspaceSidebarProjectColor(projectId: project.id, configuredHex: project.colorHex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Icon for \(project.displayName)")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Use Default") { onSelect(nil) }
                    .font(.system(size: 11))
                    .accessibilityHint("Restore the colored dot")
            }
            WorkspaceSidebarSymbolSearchField(text: $query, onCommand: handleCommand)
                .frame(height: 26)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: columns), spacing: 6) {
                        ForEach(results) { entry in
                            symbolButton(entry)
                        }
                    }
                    .padding(2)
                }
                .frame(height: 252)
                .overlay {
                    if results.isEmpty {
                        if isLoading {
                            ProgressView("Loading symbols…").controlSize(.small)
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: "magnifyingglass").font(.title2)
                                Text("No symbols found").font(.headline)
                                Text("Try another name or keyword.").font(.caption)
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .onChange(of: highlightedName) { name in
                    if let name { proxy.scrollTo(name) }
                }
            }
            HStack(spacing: 6) {
                WorkspaceSidebarProjectIcon(project: project)
                Text(project.iconName ?? "Default dot")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text("\(results.count) symbols")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 330)
        .onChange(of: query) { _ in updateResults() }
        .task {
            entries = await WorkspaceSidebarAvailableSymbols.shared.entries()
            guard !Task.isCancelled else { return }
            isLoading = false
            updateResults(preferCurrent: true)
        }
    }

    private func symbolButton(_ entry: WorkspaceSidebarSymbolCatalog.Entry) -> some View {
        Button {
            onSelect(entry.name)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: entry.name)
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.monochrome)
                    .frame(width: 20, height: 20)
                    .frame(width: 36, height: 36)
                    .background(color.opacity(highlightedName == entry.name ? 0.20 : 0.06), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(color.opacity(highlightedName == entry.name ? 0.8 : 0), lineWidth: 1.5)
                    }
                if project.iconName == entry.name {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .background(.background, in: Circle())
                        .offset(x: 1, y: 1)
                }
            }
            .foregroundStyle(color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.name)
        .accessibilityLabel(entry.name.replacingOccurrences(of: ".", with: " "))
        .accessibilityValue(project.iconName == entry.name ? "Selected" : "")
        .id(entry.name)
    }

    private func updateResults(preferCurrent: Bool = false) {
        results = WorkspaceSidebarAvailableSymbols.search(query, in: entries)
        highlightedName = preferCurrent && results.contains(where: { $0.name == project.iconName })
            ? project.iconName : results.first?.name
    }

    private func handleCommand(_ command: WorkspaceSidebarSymbolSearchCommand) {
        switch command {
            case .cancel: onCancel()
            case .select:
                if let highlightedName { onSelect(highlightedName) }
            case .move(let offset):
                guard !results.isEmpty else { return }
                let current = results.firstIndex { $0.name == highlightedName } ?? 0
                let next = workspaceSidebarSymbolSelectionIndex(current: current, offset: offset, count: results.count)
                highlightedName = results[next].name
        }
    }
}

func workspaceSidebarSymbolSelectionIndex(current: Int, offset: Int, count: Int) -> Int {
    min(max(current + offset, 0), max(count - 1, 0))
}
