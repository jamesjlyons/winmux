/// One switch keeps arrival, sidebar presentation and pinned layouts consistent.
/// The release behavior remains the default; trial profiles opt in explicitly.
enum WorkspaceInteractionMode: String, CaseIterable {
    case tiling
    case views
}
