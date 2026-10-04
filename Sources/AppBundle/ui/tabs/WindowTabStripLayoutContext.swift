import AppKit

struct WindowTabStripLayoutContext {
    let strip: WindowTabStripViewModel
    let width: CGFloat
    let tabOrder: [UInt32]
    let tabIndicesById: [UInt32: Int]

    init(strip: WindowTabStripViewModel, width: CGFloat) {
        self.strip = strip
        self.width = width
        tabOrder = strip.tabs.map(\.windowId)
        // Every tab consults this during a reorder. Build the index once per render,
        // rather than allocating a full dictionary for each tab's visual offset.
        tabIndicesById = Dictionary(uniqueKeysWithValues: tabOrder.enumerated().map { ($0.element, $0.offset) })
    }

    var tabWidth: CGFloat {
        windowTabStripTabWidth(stripWidth: width, count: max(strip.tabs.count, 1))
    }

    var effectiveTabWidth: CGFloat {
        tabWidth + windowTabStripTabSpacing
    }

    var scrollViewportWidth: CGFloat {
        windowTabStripScrollViewportWidth(stripWidth: width)
    }

    var scrollContentWidth: CGFloat {
        CGFloat(strip.tabs.count) * tabWidth
            + CGFloat(max(strip.tabs.count - 1, 0)) * windowTabStripTabSpacing
            + windowTabStripContentHorizontalPadding * 2
    }

    var scrollCoordinateSpaceName: String {
        "window-tab-strip-scroll-\(strip.id.hashValue)"
    }


    func trailingFadeWidth(contentMinX: CGFloat) -> CGFloat {
        windowTabTrailingScrollFadeWidth(
            isScrollable: shouldFadeTabScroll,
            contentMaxX: contentMinX + scrollContentWidth,
            viewportWidth: scrollViewportWidth,
            stripWidth: width,
        )
    }

    func leadingFadeWidth(contentMinX: CGFloat) -> CGFloat {
        windowTabLeadingScrollFadeWidth(
            isScrollable: shouldFadeTabScroll,
            contentMinX: contentMinX,
            stripWidth: width,
        )
    }

    private var shouldFadeTabScroll: Bool {
        scrollContentWidth > scrollViewportWidth + 1
    }
}
