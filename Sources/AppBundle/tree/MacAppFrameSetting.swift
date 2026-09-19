import AppKit

/// Reads the current frame first and returns before the AXEnhancedUserInterface round-trip when
/// the frame already matches: layout re-asserts frames constantly and the vast majority of these
/// calls are no-ops, so the no-op path must not pay the disableAnimations read.
func setFrame(_ window: AXUIElement, app: AXUIElement, _ topLeft: CGPoint?, _ size: CGSize?, _ job: RunLoopJob) throws {
    let interval = signposter.beginInterval("Apply window frame")
    defer { signposter.endInterval("Apply window frame", interval) }
    try updateWindowFrame(
        topLeft, size,
        getPosition: { window.get(Ax.topLeftCornerAttr) },
        getSize: { window.get(Ax.sizeAttr) },
        setPosition: { window.set(Ax.topLeftCornerAttr, $0) },
        setSize: { window.set(Ax.sizeAttr, $0) },
        checkCancellation: { try job.checkCancellation() },
        perform: { body in try disableAnimations(app: app, job, body) }
    )
}

/// Kept independent of AX transport so clamp/cancellation behavior can be tested faithfully.
func updateWindowFrame(
    _ topLeft: CGPoint?, _ size: CGSize?,
    getPosition: @escaping () -> CGPoint?, getSize: @escaping () -> CGSize?,
    setPosition: @escaping (CGPoint) -> Void, setSize: @escaping (CGSize) -> Void,
    checkCancellation: @escaping () throws -> Void,
    perform: (() throws -> Void) throws -> Void,
) throws {
    let currentTopLeft = topLeft == nil ? nil : getPosition()
    let currentSize = size == nil ? nil : getSize()
    let positionMatches = topLeft == nil || currentTopLeft == topLeft
    let sizeMatches = size == nil || currentSize == size
    guard !positionMatches || !sizeMatches else { return }
    try perform {
        try checkCancellation()
        let didResize = size != nil && !sizeMatches
        if let size, didResize { setSize(size) }
        try checkCancellation()
        guard let topLeft else { return }
        // Resizing can shift the origin, even if it matched before the resize.
        let shouldMove = didResize ? getPosition() != topLeft : !positionMatches
        guard shouldMove else { return }
        setPosition(topLeft)
        try checkCancellation()
        // Moving across monitors can clamp size. Correct it only when necessary.
        if let size, getSize() != size { setSize(size) }
    }
}

func disableAnimations<T>(app: AXUIElement, _ job: RunLoopJob, _ body: () throws -> T) throws -> T {
    let wasEnabled = app.get(Ax.enhancedUserInterfaceAttr) == true
    if wasEnabled {
        app.set(Ax.enhancedUserInterfaceAttr, false)
    }
    defer {
        if wasEnabled {
            app.set(Ax.enhancedUserInterfaceAttr, true)
        }
    }
    try job.checkCancellation()
    return try body()
}
