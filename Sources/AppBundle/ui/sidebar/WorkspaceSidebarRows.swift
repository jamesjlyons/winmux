import AppKit
import Common
import SwiftUI

private struct WorkspaceSidebarExternalRowSelectionKey: EnvironmentKey {
    static let defaultValue = false
}

private struct WorkspaceSidebarCompactRowsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var workspaceSidebarCompactRows: Bool {
        get { self[WorkspaceSidebarCompactRowsKey.self] }
        set { self[WorkspaceSidebarCompactRowsKey.self] = newValue }
    }
    var workspaceSidebarExternalRowSelection: Bool {
        get { self[WorkspaceSidebarExternalRowSelectionKey.self] }
        set { self[WorkspaceSidebarExternalRowSelectionKey.self] = newValue }
    }
}

// MARK: - Window Row

struct WorkspaceSidebarWindowRow: View {
    @Environment(\.workspaceSidebarMenuBarStyle) private var menuBarStyle
    @Environment(\.workspaceSidebarDensity) private var density
    @Environment(\.workspaceSidebarExternalRowSelection) private var externalSelection
    @Environment(\.workspaceSidebarCompactRows) private var isCompact
    enum Style {
        case window
        case tabGroupHeader
        case tabGroupChild
    }

    let title: String
    let badge: String?
    let isFocused: Bool
    let rowHeight: CGFloat
    let isHovered: Bool
    let style: Style
    let appBundleIds: [String?]
    let appBundlePaths: [String?]
    var favicons: [String?] = []
    var fallbackSystemImage: String = "app"
    var isSelected = false
    var isKeyboardTarget = false
    var isLoading = false

    private var isTabGroupHeader: Bool { style == .tabGroupHeader }
    private var isTabGroupChild: Bool { style == .tabGroupChild }
    private var isActiveRow: Bool { !isTabGroupHeader && (isSelected || isFocused) }
    private var chromeState: ChromeItemState {
        .init(isSelected: isSelected, isFocused: isFocused, isHovered: isHovered,
              isKeyboardTarget: isKeyboardTarget, isGroup: isTabGroupHeader)
    }

    var body: some View {
        HStack(spacing: isCompact ? 0 : workspaceSidebarAppIconTextSpacing) {
            Group {
                if isLoading {
                    ProgressView().controlSize(.mini)
                        .frame(width: workspaceSidebarAppIconSize, height: workspaceSidebarAppIconSize)
                        .accessibilityLabel("Loading")
                } else {
                    appIconStack.fixedSize()
                }
            }
            if !isCompact {
                Text(title)
                    .font(.system(size: 13, weight: isActiveRow ? .medium : .regular))
                    .foregroundStyle(rowTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if !density.isNarrow, let badge {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(isTabGroupHeader ? Color.primary.opacity(0.50) : Color.primary.opacity(0.38))
                }
            }
        }
        .padding(.leading, isCompact ? 0 : workspaceSidebarRowLeadingPadding)
        .padding(.trailing, isCompact ? 0 : workspaceSidebarRowHorizontalPadding)
        .padding(.vertical, 1)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
        .background {
            if !externalSelection {
                ChromeSelectionBackground(state: chromeState, cornerRadius: menuBarStyle ? 5 : 7)
            }
        }
        .accessibilityAddTraits(isActiveRow ? .isSelected : [])
        .accessibilityLabel(title)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var appIconStack: some View {
        if isTabGroupHeader, !appIconInputs.isEmpty {
            HStack(spacing: -3) {
                ForEach(Array(appIconInputs.prefix(density.isNarrow ? 1 : 4).enumerated()), id: \.offset) { _, input in
                    appIcon(input)
                }
            }
        } else if let input = appIconInputs.first {
            appIcon(input)
        } else {
            fallbackIcon
        }
    }

    private var appIconInputs: [(String?, String?, String?)] {
        (0..<max(appBundleIds.count, appBundlePaths.count, favicons.count)).map { index in
            (appBundleIds.getOrNil(atIndex: index) ?? nil, appBundlePaths.getOrNil(atIndex: index) ?? nil,
             favicons.getOrNil(atIndex: index) ?? nil)
        }.filter { $0.0 != nil || $0.1 != nil || $0.2 != nil }
    }

    private func appIcon(_ input: (String?, String?, String?)) -> some View {
        Group {
            if let icon = workspaceSidebarIconImage(favicon: input.2, bundleIdentifier: input.0, bundlePath: input.1) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: workspaceSidebarAppIconSize, height: workspaceSidebarAppIconSize)
                    .cornerRadius(3)
                    .opacity(rowIconOpacity)
            } else {
                fallbackIcon
            }
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: fallbackSystemImage)
            .font(.system(size: workspaceSidebarAppIconSize))
            .foregroundStyle(Color.primary.opacity(0.45))
            .frame(width: workspaceSidebarAppIconSize, height: workspaceSidebarAppIconSize)
    }

    private var rowTextColor: Color {
        if menuBarStyle { return Color.primary.opacity(isTabGroupChild ? 0.78 : 0.95) }
        if isActiveRow {
            return Color.primary.opacity(isTabGroupHeader ? 0.96 : 1)
        }
        if isTabGroupChild {
            return Color.primary.opacity(0.72)
        }
        return Color.primary.opacity(0.78)
    }

    private var rowIconOpacity: Double {
        isTabGroupChild && !isActiveRow ? 0.8 : 1
    }

}
