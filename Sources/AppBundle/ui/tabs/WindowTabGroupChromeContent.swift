import CoreGraphics

struct WindowTabGroupChromeContent: Equatable {
    let workspaceName: String
    let activeWindowId: UInt32?
    let activeWindowCornerRadius: CGFloat
    let tabs: [WindowTabItemViewModel]
    let occludingFloatingWindowFrames: [CGRect]
    let chromeStyle: ChromeStyle
    let solidChromeColor: ChromeSolidColor
    let solidChromeCustomColor: String

    @MainActor init(strip: WindowTabStripViewModel) {
        workspaceName = strip.workspaceName
        activeWindowId = strip.activeWindowId
        activeWindowCornerRadius = strip.activeWindowCornerRadius
        tabs = strip.tabs
        occludingFloatingWindowFrames = strip.occludingFloatingWindowFrames
        chromeStyle = config.workspaceSidebar.chromeStyle
        solidChromeColor = config.workspaceSidebar.solidChromeColor
        solidChromeCustomColor = config.workspaceSidebar.solidChromeCustomColor
    }
}

/// The frame has no tab titles or selection highlight. Keep that larger model
/// out of its rendering identity so tab/title changes only update the controls.
struct WindowTabGroupVisualContent: Equatable {
    let tabBarHeight: CGFloat
    let activeWindowCornerRadius: CGFloat
    let localOcclusionRects: [CGRect]
    let chromeStyle: ChromeStyle
    let solidChromeColor: ChromeSolidColor
    let solidChromeCustomColor: String

    @MainActor init(strip: WindowTabStripViewModel) {
        tabBarHeight = strip.frame.height
        activeWindowCornerRadius = strip.activeWindowCornerRadius
        localOcclusionRects = windowTabLocalOcclusionRects(
            panelFrame: strip.groupFrame,
            occludingScreenFrames: strip.occludingFloatingWindowFrames,
        )
        chromeStyle = config.workspaceSidebar.chromeStyle
        solidChromeColor = config.workspaceSidebar.solidChromeColor
        solidChromeCustomColor = config.workspaceSidebar.solidChromeCustomColor
    }
}
