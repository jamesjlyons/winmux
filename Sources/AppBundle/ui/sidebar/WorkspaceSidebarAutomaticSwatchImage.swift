import AppKit

func workspaceSidebarAutomaticColorSwatchImage(isSelected: Bool) -> NSImage {
    workspaceSidebarSwatchImage {
        drawWorkspaceSidebarSwatchCircle(
            fill: NSColor.labelColor.withAlphaComponent(isSelected ? 0.20 : 0.10),
            stroke: NSColor.labelColor.withAlphaComponent(isSelected ? 0.75 : 0.35),
            lineWidth: isSelected ? 1.4 : 1,
        )
        drawWorkspaceSidebarAutomaticSwatchSlash()
    }
}

func drawWorkspaceSidebarAutomaticSwatchSlash() {
    let slashPath = NSBezierPath()
    slashPath.move(to: NSPoint(x: 4.3, y: 4.4))
    slashPath.line(to: NSPoint(x: 11.7, y: 11.6))
    slashPath.lineCapStyle = .round
    slashPath.lineWidth = 1.2
    NSColor.labelColor.withAlphaComponent(0.72).setStroke()
    slashPath.stroke()
}
