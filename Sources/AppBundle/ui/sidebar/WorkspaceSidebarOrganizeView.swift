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
            Circle()
                .fill(workspaceSidebarProjectColor(projectId: project.id, configuredHex: project.colorHex))
                .frame(width: 7, height: 7)
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

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollDuringDrag() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scrollDuringDrag() {
        guard isLeftMouseButtonDown,
              isWorkspaceSidebarDragInProgress() || isMouseWindowDragInProgress(),
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
}
