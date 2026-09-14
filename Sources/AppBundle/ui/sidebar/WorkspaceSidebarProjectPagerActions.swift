import AppKit
import Common
import SwiftUI

extension WorkspaceSidebarProjectPager {
    @ViewBuilder
    var compactProjectIndicator: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .center, spacing: 0) {
                    ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                        projectDot(project, index: index)
                            .id(project.id)
                    }
                }
                .frame(width: sectionWidth, alignment: .center)
            }
            .frame(width: sectionWidth, height: compactProjectControlsHeight, alignment: .center)
            .background(WorkspaceSidebarProjectScrollRegion())
            .clipped()
            .onAppear {
                scrollCompactProjectTrackToCurrent(proxy)
            }
            .onChange(of: selectedProjectId) { _ in
                scrollCompactProjectTrackToCurrent(proxy)
            }
            .onChange(of: compactProjectControlsHeight) { _ in
                scrollCompactProjectTrackToCurrent(proxy)
            }
        }
    }

    var projectDotTrack: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 4) {
                    ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                        projectDot(project, index: index)
                            .id(project.id)
                    }
                }
                .padding(.horizontal, 4)
                .frame(minHeight: workspaceSidebarPagerHeight, alignment: .leading)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear {
                                updateProjectTrackMetrics(geometry)
                            }
                            .onChange(of: geometry.frame(in: .named("workspaceSidebarProjectTrack")).minX) { _ in
                                updateProjectTrackMetrics(geometry)
                            }
                            .onChange(of: geometry.size.width) { _ in
                                updateProjectTrackMetrics(geometry)
                            }
                    }
                }
            }
            .frame(width: projectTrackWidth, height: workspaceSidebarPagerHeight, alignment: .leading)
            .background(WorkspaceSidebarProjectScrollRegion())
            .coordinateSpace(name: "workspaceSidebarProjectTrack")
            .clipped()
            .mask(projectTrackFadeMask)
            .onAppear {
                scrollProjectTrackToCurrent(proxy)
            }
            .onChange(of: selectedProjectId) { _ in
                scrollProjectTrackToCurrent(proxy)
            }
            .onChange(of: projectTrackScrollTargetId) { projectId in
                scrollProjectTrack(to: projectId, proxy: proxy)
            }
            .onChange(of: projectTrackWidth) { _ in
                scrollProjectTrackToCurrent(proxy)
            }
        }
    }

    private var projectTrackFadeMask: some View {
        let showsLeadingFade = projectTrackContentMinX < -2
        let showsTrailingFade = projectTrackContentMinX + projectTrackContentWidth > projectTrackViewportWidth + 2
        return LinearGradient(
            stops: [
                .init(color: showsLeadingFade ? .clear : .black, location: 0),
                .init(color: .black, location: showsLeadingFade ? 0.08 : 0),
                .init(color: .black, location: showsTrailingFade ? 0.92 : 1),
                .init(color: showsTrailingFade ? .clear : .black, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func updateProjectTrackMetrics(_ geometry: GeometryProxy) {
        let frame = geometry.frame(in: .named("workspaceSidebarProjectTrack"))
        projectTrackContentMinX = frame.minX
        projectTrackContentWidth = geometry.size.width
        projectTrackViewportWidth = projectTrackWidth
    }

    private func scrollProjectTrackToCurrent(_ proxy: ScrollViewProxy) {
        guard let selectedProject else { return }
        scrollProjectTrack(to: selectedProject.id, proxy: proxy)
    }

    private func scrollProjectTrack(to projectId: WorkspaceProjectId?, proxy: ScrollViewProxy) {
        guard let projectId else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(projectId, anchor: .center)
        }
    }

    private func scrollCompactProjectTrackToCurrent(_ proxy: ScrollViewProxy) {
        guard let selectedProject else { return }
        scrollProjectTrack(to: selectedProject.id, proxy: proxy)
    }

    @ViewBuilder
    func projectContextMenuItems(for project: WorkspaceSidebarProjectViewModel) -> some View {
        Button("Rename Project") {
            onBeginRenameProject(project)
        }
        Menu("Color") {
            let selectedColorHex = project.colorHex.flatMap(normalizedWorkspaceSidebarColorHex)
            Button {
                onSetProjectColor(project, nil)
            } label: {
                Label {
                    Text("Auto")
                } icon: {
                    Image(nsImage: workspaceSidebarAutomaticColorSwatchImage(isSelected: selectedColorHex == nil))
                }
            }
            Divider()
            ForEach(workspaceSidebarProjectColorPresets) { preset in
                Button {
                    onSetProjectColor(project, preset.hex)
                } label: {
                    Label {
                        Text(preset.name)
                    } icon: {
                        Image(nsImage: workspaceSidebarProjectColorSwatchImage(
                            hex: preset.hex,
                            isSelected: selectedColorHex == preset.hex,
                        ))
                    }
                }
            }
        }
        Button(role: .destructive) {
            onDeleteProject(project)
        } label: {
            Text("Delete Project")
        }
        .disabled(!canDeleteWorkspaceProject(project.id))
    }
}
