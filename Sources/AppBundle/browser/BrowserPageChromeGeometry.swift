import AppKit
import WorkspaceCore

/// One geometry calculation owns the page's complete silhouette. The planner's
/// allocation includes gutters, the native header and the thin frame around the
/// Chromium content, so none of them float outside their page's layout bounds.
struct BrowserPageChromeGeometry: Equatable {
    static let gutter = 4
    static let shellInset = 1
    static let headerHeight = 36
    static let cornerRadius: CGFloat = 14
    static let widthOverhead = (gutter + shellInset) * 2
    static let heightOverhead = gutter * 2 + headerHeight + shellInset

    let pageFrame: SurfaceFrame
    let headerFrame: SurfaceFrame
    let bodyFrame: SurfaceFrame

    init?(frame: SurfaceFrame) {
        guard frame.isValid, frame.width > Self.widthOverhead,
              frame.height > Self.heightOverhead else { return nil }
        pageFrame = .init(x: frame.x + Self.gutter, y: frame.y + Self.gutter,
                          width: frame.width - Self.gutter * 2, height: frame.height - Self.gutter * 2)
        headerFrame = .init(x: pageFrame.x, y: pageFrame.y,
                            width: pageFrame.width, height: Self.headerHeight)
        bodyFrame = .init(x: pageFrame.x + Self.shellInset, y: pageFrame.y + Self.headerHeight,
                          width: pageFrame.width - Self.shellInset * 2,
                          height: pageFrame.height - Self.headerHeight - Self.shellInset)
        guard pageFrame.isValid, headerFrame.isValid, bodyFrame.isValid else { return nil }
    }

    /// Chromium and the planner use global top-left coordinates. AppKit uses the
    /// primary display's top edge as its screen-coordinate vertical origin.
    static func appKitRect(_ frame: SurfaceFrame, screenTop: CGFloat) -> CGRect {
        .init(x: CGFloat(frame.x), y: screenTop - CGFloat(frame.y + frame.height),
              width: CGFloat(frame.width), height: CGFloat(frame.height))
    }
}
