import SwiftUI

enum WorkspaceSidebarTabStyle {
    static let cornerRadius: CGFloat = 16
    static let verticalInset: CGFloat = 1
    static let darkBackground = Color(chromeHex: "#111111")
    static let darkRestingTitle = Color(chromeHex: "#A3A3A3")
    static let darkEmphasizedTitle = Color(chromeHex: "#EEEEEE")
    static let darkGroupHeading = Color(chromeHex: "#757575")
}

/// Most travel finishes in ~170 ms; the critically damped tail settles quietly.
enum WorkspaceSidebarTabMotion {
    static let movement = Animation.interpolatingSpring(mass: 1, stiffness: 529, damping: 46)
    static let hover = Animation.easeOut(duration: 0.065)
    static let removal = Animation.easeOut(duration: 0.09)
    static let filtering = Animation.easeOut(duration: 0.18)
    static let selectionFade = Animation.easeOut(duration: 0.12)
    static let reorder = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.14)

    static func transition(reduceMotion: Bool, isFiltering: Bool = false) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        if isFiltering {
            return .asymmetric(insertion: .opacity.animation(filtering), removal: .opacity.animation(removal))
        }
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
    var cornerRadius: CGFloat = WorkspaceSidebarTabStyle.cornerRadius
    @Environment(\.workspaceSidebarTabMotion) private var usesMotion
    @Environment(\.workspaceSidebarMenuBarStyle) private var menuBarStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ChromeSelectionBackground(state: localState, cornerRadius: cornerRadius,
                                  transition: reduceMotion ? nil : WorkspaceSidebarTabMotion.hover,
                                  palette: menuBarStyle ? .standard : .sidebar)
            .padding(.vertical, menuBarStyle ? 0 : WorkspaceSidebarTabStyle.verticalInset)
            .anchorPreference(key: WorkspaceSidebarTabAnchorKey.self, value: .bounds) { bounds in
                if usesMotion, let id, state.isRaised {
                    return [.init(id: id, state: state, bounds: bounds)]
                }
                return []
            }
    }

    private var localState: ChromeItemState {
        if state.isGroup && !menuBarStyle {
            // The heading's active dot carries selection without a second pill.
            return .init(isHovered: state.isHovered, isKeyboardTarget: state.isKeyboardTarget, isGroup: true)
        }
        guard usesMotion, id != nil, state.isRaised else { return state }
        // Preserve keyboard focus independently of the moving selected surface.
        return .init(isKeyboardTarget: state.isKeyboardTarget)
    }
}

/// One persistent view per project page. The scroll view moves this layer with
/// its rows; scrolling does not retarget the spring or require state publications.
struct WorkspaceSidebarTabMotionScope: ViewModifier {
    var isEnabled = true
    var viewportHeight: CGFloat? = nil

    func body(content: Content) -> some View {
        content
            .environment(\.workspaceSidebarTabMotion, isEnabled)
            .environment(\.tabSelectionAppearance, isEnabled
                ? .init(cornerRadius: WorkspaceSidebarTabStyle.cornerRadius,
                        verticalInset: WorkspaceSidebarTabStyle.verticalInset)
                : .init())
            .backgroundPreferenceValue(WorkspaceSidebarTabAnchorKey.self) { anchors in
                GeometryReader { geometry in
                    if isEnabled {
                        let primary = anchors.first(where: { $0.state.isFocused }) ?? anchors.first
                        // Other stacks retain their saved selection even when a
                        // different stack owns keyboard focus.
                        ForEach(anchors.filter { $0.id != primary?.id }, id: \.id) { anchor in
                            let frame = geometry[anchor.bounds].insetBy(dx: 0, dy: WorkspaceSidebarTabStyle.verticalInset)
                            ChromeSelectionBackground(state: anchor.state,
                                                      cornerRadius: WorkspaceSidebarTabStyle.cornerRadius,
                                                      transition: nil, palette: .sidebar)
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                        }
                        let target = primary.map {
                            WorkspaceSidebarSelectionTarget(id: $0.id,
                                bounds: geometry[$0.bounds].insetBy(dx: 0, dy: WorkspaceSidebarTabStyle.verticalInset),
                                isFocused: $0.state.isFocused)
                        }
                        let viewport = viewportHeight.map {
                            CGRect(x: 0, y: -geometry.frame(in: .named("workspaceSidebarTabViewport")).minY,
                                   width: geometry.size.width, height: $0)
                        }
                        WorkspaceSidebarTabSelectionLayer(target: target, viewport: viewport)
                    }
                }
                .transaction { $0.animation = nil }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

struct WorkspaceSidebarSelectionTarget: Equatable {
    let id: String
    let bounds: CGRect
    let isFocused: Bool
}

enum WorkspaceSidebarSelectionMotion {
    case immediate, travel, fade

    static func resolve(from previous: WorkspaceSidebarSelectionTarget?, to next: WorkspaceSidebarSelectionTarget?,
                        viewport: CGRect?, reduceMotion: Bool) -> Self {
        guard !reduceMotion else { return .immediate }
        guard let previous, let next else { return .fade }
        // Reflow and scrolling supply presentation geometry. Applying another
        // spring to the same tab would make its pill lag behind its label.
        guard previous.id != next.id else { return .immediate }
        let distance = abs(previous.bounds.midY - next.bounds.midY)
        guard distance <= 5 * max(previous.bounds.height, next.bounds.height) else { return .fade }
        if let viewport, !viewport.contains(previous.bounds) || !viewport.contains(next.bounds) { return .fade }
        return .travel
    }
}

private struct WorkspaceSidebarTabSelectionLayer: View {
    let target: WorkspaceSidebarSelectionTarget?
    let viewport: CGRect?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayed: WorkspaceSidebarSelectionTarget?
    @State private var generation = 0
    @State private var selectionAnimation: Animation?

    var body: some View {
        ZStack {
            if let displayed {
                WorkspaceSidebarMovingTabSelection(bounds: displayed.bounds, isFocused: displayed.isFocused)
                    .id(generation)
                    .transition(.opacity)
            }
        }
        .animation(selectionAnimation, value: displayed)
        .onAppear { displayed = target }
        .onChange(of: target) { next in
            switch WorkspaceSidebarSelectionMotion.resolve(from: displayed, to: next,
                                                            viewport: viewport, reduceMotion: reduceMotion) {
            case .immediate:
                selectionAnimation = nil
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { displayed = next }
            case .travel:
                selectionAnimation = WorkspaceSidebarTabMotion.movement
                withAnimation(WorkspaceSidebarTabMotion.movement) { displayed = next }
            case .fade:
                selectionAnimation = WorkspaceSidebarTabMotion.selectionFade
                withAnimation(WorkspaceSidebarTabMotion.selectionFade) {
                    generation += 1
                    displayed = next
                }
            }
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
            .fill(ChromeSelectionPalette.sidebar.selectionColor(dark: colorScheme == .dark, focused: isFocused))
            .shadow(color: .black.opacity(ChromeSelectionPalette.sidebar.shadowOpacity(
                dark: colorScheme == .dark, focused: isFocused)), radius: 2, y: 1)
            .overlay {
                WorkspaceSidebarPositionedTabShape(bounds: bounds)
                    .stroke(ChromeSelectionPalette.sidebar.outlineColor(dark: colorScheme == .dark,
                                focused: isFocused, increasedContrast: contrast == .increased),
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
        RoundedRectangle(cornerRadius: WorkspaceSidebarTabStyle.cornerRadius, style: .continuous).path(in: rect)
    }
}

extension WorkspaceSidebarItemViewModel {
    /// Deliberately excludes titles, favicons, loading and focus updates.
    var tabLayoutIdentity: [String] {
        switch kind {
        case .surfaceGroup(_, let children): [id] + children.flatMap(\.tabLayoutIdentity)
        case .tabGroup(let group): [id] + (group.searchVisibleTabs ?? group.tabs).map { $0.surfaceID.description }
        default: [id]
        }
    }
}
