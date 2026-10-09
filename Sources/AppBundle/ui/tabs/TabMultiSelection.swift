import AppKit
import SwiftUI
import WorkspaceCore

/// Transient editing selection, independent of the focused/visible tab.
struct TabMultiSelection<ID: Hashable & Sendable>: Equatable, Sendable {
    private(set) var selected: Set<ID> = []
    private(set) var anchor: ID?
    private(set) var isEditingSelection = false

    mutating func click(_ id: ID, order: [ID], shift: Bool, command: Bool, fallback: ID? = nil) {
        prune(to: order)
        guard order.contains(id) else { return }
        isEditingSelection = shift || command
        if shift, let start = (anchor ?? fallback).flatMap({ order.firstIndex(of: $0) }),
           let end = order.firstIndex(of: id) {
            if anchor == nil { anchor = order[start] }
            let range = Set(order[min(start, end)...max(start, end)])
            selected = command ? selected.union(range) : range
        } else if command {
            if anchor == nil, selected.isEmpty, let fallback, order.contains(fallback) { selected.insert(fallback) }
            if !selected.insert(id).inserted { selected.remove(id) }
            anchor = id
        } else {
            selected = [id]
            anchor = id
        }
    }

    mutating func prune(to order: [ID]) {
        selected.formIntersection(order)
        if let anchor, !order.contains(anchor) { self.anchor = nil }
    }

    func targets(for id: ID, order: [ID]) -> [ID] {
        selected.contains(id) ? order.filter { selected.contains($0) } : [id]
    }

    mutating func contextClick(_ id: ID, order: [ID]) {
        prune(to: order)
        if !selected.contains(id) { click(id, order: order, shift: false, command: false) }
    }
}

@MainActor
final class TabSelectionModel: ObservableObject {
    @Published var state = TabMultiSelection<SurfacePane>()
}

struct TabSelectionContext: Sendable {
    var model: TabSelectionModel?
    var state = TabMultiSelection<SurfacePane>()
    var order: [SurfacePane] = []

    @MainActor
    func activate(_ pane: SurfacePane) -> Bool {
        guard let model else { return true }
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        let focused = BrowserWorkspaceController.shared.focusCoordinator.target ?? focus.windowOrNil?.surfaceID
        let fallback = focused.flatMap { id in order.first { pane in
            if pane == .surface(id) { return true }
            return BrowserWorkspaceController.shared.surfaceTree.node(for: pane)?.surfaces.contains(id) == true
        } }
        model.state.click(pane, order: order, shift: flags.contains(.shift), command: flags.contains(.command), fallback: fallback)
        return !flags.contains(.shift) && !flags.contains(.command)
    }

    func targets(for pane: SurfacePane) -> [SurfacePane] { state.targets(for: pane, order: order) }
    func isMarked(_ pane: SurfacePane) -> Bool { state.isEditingSelection && state.selected.contains(pane) }

    @MainActor var allowsDrag: Bool {
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        return state.selected.count <= 1 && flags.intersection([.shift, .command]).isEmpty
    }
}

private struct TabSelectionContextKey: EnvironmentKey {
    static let defaultValue = TabSelectionContext()
}

extension EnvironmentValues {
    var tabSelection: TabSelectionContext {
        get { self[TabSelectionContextKey.self] }
        set { self[TabSelectionContextKey.self] = newValue }
    }
}

private struct TabSelectionOrderKey: PreferenceKey {
    static let defaultValue: [SurfacePane] = []
    static func reduce(value: inout [SurfacePane], nextValue: () -> [SurfacePane]) { value += nextValue() }
}

private struct TabSelectionRoot: ViewModifier {
    let scope: String
    @StateObject private var model = TabSelectionModel()
    @State private var order: [SurfacePane] = []

    func body(content: Content) -> some View {
        content
            .environment(\.tabSelection, .init(model: model, state: model.state, order: order))
            .onPreferenceChange(TabSelectionOrderKey.self) { values in
                var seen: Set<SurfacePane> = []
                let next = values.filter { seen.insert($0).inserted }
                if next != order { order = next; model.state.prune(to: next) }
            }
            .onChange(of: scope) { _ in model.state = .init() }
    }
}

private struct TabSelectionItem: ViewModifier {
    let pane: SurfacePane?
    @Environment(\.tabSelection) private var selection

    func body(content: Content) -> some View {
        content
            .preference(key: TabSelectionOrderKey.self, value: pane.map { [$0] } ?? [])
            .overlay {
                if let pane, selection.isMarked(pane) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.primary.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.65), lineWidth: 1.5))
                        .allowsHitTesting(false)
                }
            }
            .accessibilityAddTraits(pane.map(selection.isMarked) == true ? .isSelected : [])
    }
}

extension View {
    func tabSelectionRoot(scope: String) -> some View { modifier(TabSelectionRoot(scope: scope)) }
    func tabSelectionItem(_ pane: SurfacePane?) -> some View { modifier(TabSelectionItem(pane: pane)) }
}
