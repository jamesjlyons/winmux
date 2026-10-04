import AppKit
import SwiftUI

extension WorkspaceSidebarView {
    func organizeWorkspacePage(
        expansionProgress: CGFloat,
        topPadding: CGFloat,
        visibleWorkspacesByProject: [WorkspaceProjectId: [WorkspaceSidebarWorkspaceViewModel]]
    ) -> some View {
        let columnWidth = workspaceSidebarSectionWidth(expansionProgress, layout: snapshot.configuration)
        return GeometryReader { geometry in
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: WorkspaceSidebarOrganizeLayout.gap) {
                        ForEach(snapshot.projects) { project in
                            VStack(alignment: .leading, spacing: 6) {
                                organizeProjectHeading(project)
                                workspacePage(
                                    projectId: project.id,
                                    workspaces: visibleWorkspacesByProject[project.id] ?? [],
                                    expansionProgress: expansionProgress,
                                    leadingInset: 0,
                                    trailingInset: 0,
                                    topPadding: topPadding,
                                    isInteractive: true,
                                    showsPinnedActiveWorkspace: false,
                                    allowsActivation: allowsWorkspaceActivation(projectId: project.id)
                                )
                            }
                            .frame(width: columnWidth, height: max(0, geometry.size.height - 12), alignment: .topLeading)
                            .id(project.id)
                        }
                    }
                    .padding(.horizontal, WorkspaceSidebarOrganizeLayout.inset)
                    .background(WorkspaceSidebarOrganizeScrollBridge())
                }
                .workspaceSidebarDropViewport()
                .onAppear {
                    if snapshot.projects.first?.id != snapshot.activeProjectId {
                        reader.scrollTo(snapshot.activeProjectId, anchor: .leading)
                    }
                }
                .onChange(of: selectedSearchTarget) { selection in
                    guard let selection,
                          let workspace = snapshot.workspaces.first(where: { workspace in
                              workspaceSidebarSearchSelections(workspaces: [workspace]).contains(selection)
                          }) else { return }
                    reader.scrollTo(workspace.projectId)
                }
            }
        }
    }

    private func organizeProjectHeading(_ project: WorkspaceSidebarProjectViewModel) -> some View {
        HStack(spacing: 6) {
            WorkspaceSidebarProjectIcon(project: project)
            Text(project.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if project.id == snapshot.activeProjectId {
                Text("Active").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(height: 28)
        .accessibilityElement(children: .combine)
    }
}

/// Lives inside the horizontal scroll content, so the native scroll view remains
/// responsible for trackpad scrolling, momentum, scrollbars and accessibility.
struct WorkspaceSidebarOrganizeScrollBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> WorkspaceSidebarOrganizeScrollView { .init() }
    func updateNSView(_ nsView: WorkspaceSidebarOrganizeScrollView, context: Context) {}
    static func dismantleNSView(_ nsView: WorkspaceSidebarOrganizeScrollView, coordinator: ()) { nsView.stop() }
}

final class WorkspaceSidebarOrganizeScrollView: NSView {
    private var timer: Timer?
    private var eventMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var observedDrag = false
    private var isObserving = false
    var isDragButtonDown: () -> Bool = { isLeftMouseButtonDown }
    var isAutoscrolling: Bool { timer != nil }

    private var isPresented: Bool {
        window?.isVisible == true && window?.isMiniaturized == false &&
            window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
        isObserving = true
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshActivity() }
            })
        }
        for name in [workspaceSidebarDragPointerChangedNotification, workspaceSidebarDragPointerEndedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let ended = notification.name == workspaceSidebarDragPointerEndedNotification
                MainActor.assumeIsolated { self?.noteDragActivity(ended: ended) }
            })
        }
        refreshActivity()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refreshActivity()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshActivity()
    }

    func refreshActivity() {
        guard isObserving, isPresented else {
            stopAutoscroll()
            removeEventMonitors()
            return
        }
        if eventMonitors.isEmpty {
            if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp], handler: { [weak self] event in
                self?.noteDragActivity(ended: event.type == .leftMouseUp)
                return event
            }) { eventMonitors.append(local) }
            if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp], handler: { [weak self] event in
                let ended = event.type == .leftMouseUp
                MainActor.assumeIsolated { self?.noteDragActivity(ended: ended) }
            }) { eventMonitors.append(global) }
        }
        // A drag can reveal the organize view before its next pointer event.
        observedDrag = observedDrag || isWorkspaceSidebarDragInProgress() || isMouseWindowDragInProgress()
        guard observedDrag, isDragButtonDown() else {
            stopAutoscroll()
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollDuringDrag() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func noteDragActivity(ended: Bool) {
        guard isObserving else { return }
        if ended {
            refreshTask?.cancel()
            refreshTask = nil
            stopAutoscroll()
            return
        }
        observedDrag = true
        guard timer == nil, refreshTask == nil else { return }
        // Drag notifications/event monitors can precede the model's drag-begin
        // handler. Check presentation after that handler, without polling at idle.
        refreshTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            self?.refreshTask = nil
            self?.refreshActivity()
        }
    }

    func stop() {
        isObserving = false
        refreshTask?.cancel()
        refreshTask = nil
        stopAutoscroll()
        removeEventMonitors()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func removeEventMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors = []
    }

    private func stopAutoscroll() {
        observedDrag = false
        timer?.invalidate()
        timer = nil
    }

    private func scrollDuringDrag() {
        guard isPresented, isDragButtonDown() else {
            refreshActivity()
            return
        }
        guard isWorkspaceSidebarDragInProgress() || isMouseWindowDragInProgress(),
              let scrollView = enclosingScrollView,
              let document = scrollView.documentView,
              let window
        else { return }
        let clip = scrollView.contentView
        let point = clip.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard clip.bounds.contains(point) else { return }
        let step = workspaceSidebarOrganizeScrollStep(pointerX: point.x - clip.bounds.minX, viewportWidth: clip.bounds.width)
        let x = min(max(0, clip.bounds.minX + step), max(0, document.bounds.width - clip.bounds.width))
        guard x != clip.bounds.minX else { return }
        clip.scroll(to: CGPoint(x: x, y: clip.bounds.minY))
        scrollView.reflectScrolledClipView(clip)
    }

    isolated deinit {
        refreshTask?.cancel()
        timer?.invalidate()
        eventMonitors.forEach(NSEvent.removeMonitor)
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
