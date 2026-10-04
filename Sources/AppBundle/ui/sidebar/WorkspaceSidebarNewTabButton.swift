import SwiftUI

struct WorkspaceSidebarNewTabButton: View {
    let isCompact: Bool
    let onOpen: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "plus.square")
                    .font(.system(size: 13, weight: .medium))
                if !isCompact {
                    Text("New Tab")
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(Color.primary.opacity(isHovered ? 0.9 : 0.6))
            .frame(maxWidth: .infinity, minHeight: 30, alignment: isCompact ? .center : .leading)
            .padding(.horizontal, isCompact ? 0 : 10)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("New Tab")
        .help("Open a browser tab in this group")
    }
}
