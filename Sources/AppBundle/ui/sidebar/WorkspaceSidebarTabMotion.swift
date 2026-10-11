import SwiftUI

/// Most travel finishes in ~170 ms; the critically damped tail settles quietly.
enum WorkspaceSidebarTabMotion {
    static let movement = Animation.interpolatingSpring(mass: 1, stiffness: 529, damping: 46)
    static let hover = Animation.easeOut(duration: 0.065)
    static let removal = Animation.easeOut(duration: 0.09)
    static let reorder = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.14)

    static func transition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .modifier(
                active: WorkspaceSidebarTabEntryOffset(offset: CGSize(width: 8, height: 6)).ignoredByLayout(),
                identity: WorkspaceSidebarTabEntryOffset(offset: .zero).ignoredByLayout()
            ).combined(with: .opacity).animation(movement),
            removal: .opacity.animation(removal)
        )
    }
}

/// The new content moves, but its selection anchor is already at its final slot.
/// Feeding the presentation offset back into the selection spring repeatedly
/// retargets it during the same layout pass.
private struct WorkspaceSidebarTabEntryOffset: GeometryEffect {
    var offset: CGSize
    var animatableData: CGSize.AnimatableData {
        get { offset.animatableData }
        set { offset.animatableData = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: offset.width, y: offset.height))
    }
}

private struct WorkspaceSidebarTabMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var workspaceSidebarTabMotion: Bool {
        get { self[WorkspaceSidebarTabMotionKey.self] }
        set { self[WorkspaceSidebarTabMotionKey.self] = newValue }
    }
}

private struct WorkspaceSidebarTabAnchor {
    let id: String
    let state: ChromeItemState
    let bounds: Anchor<CGRect>
}

private struct WorkspaceSidebarTabAnchorKey: PreferenceKey {
    static let defaultValue: [WorkspaceSidebarTabAnchor] = []

    static func reduce(value: inout [WorkspaceSidebarTabAnchor], nextValue: () -> [WorkspaceSidebarTabAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

/// The row owns hover and keyboard feedback. Its raised surface belongs to the
/// scroll-content layer, so changing selection never moves or crossfades labels.
struct WorkspaceSidebarTabBackground: View {
    let id: String?
    let state: ChromeItemState
    var cornerRadius: CGFloat = 7
    @Environment(\.workspaceSidebarTabMotion) private var usesMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ChromeSelectionBackground(state: localState, cornerRadius: cornerRadius,
                                  transition: reduceMotion ? nil : WorkspaceSidebarTabMotion.hover)
            .padding(usesMotion && !state.isRaised ? 2 : 0)
            .anchorPreference(key: WorkspaceSidebarTabAnchorKey.self, value: .bounds) { bounds in
                if usesMotion, let id, state.isRaised {
                    return [.init(id: id, state: state, bounds: bounds)]
                }
                return []
            }
    }

    private var localState: ChromeItemState {
        guard usesMotion, id != nil, state.isRaised else { return state }
        // Preserve keyboard focus independently of the moving selected surface.
        return .init(isKeyboardTarget: state.isKeyboardTarget)
    }
}

/// One persistent view per project page. The scroll view moves this layer with
/// its rows; scrolling does not retarget the spring or require state publications.
struct WorkspaceSidebarTabMotionScope: ViewModifier {
    var isEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.workspaceSidebarTabMotion, isEnabled)
            .backgroundPreferenceValue(WorkspaceSidebarTabAnchorKey.self) { anchors in
                GeometryReader { geometry in
                    if isEnabled, let primary = anchors.first(where: { $0.state.isFocused }) ?? anchors.first {
                        // Other stacks retain their saved selection even when a
                        // different stack owns keyboard focus.
                        ForEach(anchors.filter { $0.id != primary.id }, id: \.id) { anchor in
                            let frame = geometry[anchor.bounds]
                            ChromeSelectionBackground(state: anchor.state, cornerRadius: 7, transition: nil)
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                        }
                        let frame = geometry[primary.bounds]
                        WorkspaceSidebarMovingTabSelection(bounds: frame, isFocused: primary.state.isFocused)
                            // Geometry from an existing row already includes its
                            // layout animation. Only a new selection needs a spring.
                            .animation(reduceMotion ? nil : WorkspaceSidebarTabMotion.movement, value: primary.id)
                    }
                }
                .transaction { $0.animation = nil }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

private struct WorkspaceSidebarMovingTabSelection: View {
    let bounds: CGRect
    let isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        WorkspaceSidebarPositionedTabShape(bounds: bounds)
            .fill(ChromeControlToken.selectionColor(dark: colorScheme == .dark, focused: isFocused))
            .overlay {
                WorkspaceSidebarPositionedTabShape(bounds: bounds)
                    .stroke(Color.primary.opacity(contrast == .increased ? 0.55 : 0.12),
                            lineWidth: contrast == .increased ? 1 : 0.5)
            }
    }
}

/// Draw in scroll-content coordinates so selection travel stays independent of
/// size changes to the list's canvas.
private struct WorkspaceSidebarPositionedTabShape: Shape {
    var bounds: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(bounds.minX, bounds.minY), .init(bounds.width, bounds.height)) }
        set {
            bounds = CGRect(x: newValue.first.first, y: newValue.first.second,
                            width: newValue.second.first, height: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        WorkspaceSidebarRoundedTabShape().path(in: bounds)
    }
}

/// Both edges share the same radius and curve, with a continuous closed outline.
struct WorkspaceSidebarRoundedTabShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(8, rect.height / 2, rect.width / 3)
        var path = Path()
        path.move(to: .init(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: .init(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: .init(x: rect.maxX, y: rect.minY + radius), control: .init(x: rect.maxX, y: rect.minY))
        path.addLine(to: .init(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: .init(x: rect.maxX - radius, y: rect.maxY), control: .init(x: rect.maxX, y: rect.maxY))
        path.addLine(to: .init(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: .init(x: rect.minX, y: rect.maxY - radius), control: .init(x: rect.minX, y: rect.maxY))
        path.addLine(to: .init(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: .init(x: rect.minX + radius, y: rect.minY), control: .init(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

extension WorkspaceSidebarItemViewModel {
    /// Deliberately excludes titles, favicons, loading and focus updates.
    var tabLayoutIdentity: [String] {
        switch kind {
        case .surfaceGroup(_, let children): [id] + children.flatMap(\.tabLayoutIdentity)
        case .tabGroup(let group): [id] + group.tabs.map { $0.surfaceID.description }
        default: [id]
        }
    }
}
