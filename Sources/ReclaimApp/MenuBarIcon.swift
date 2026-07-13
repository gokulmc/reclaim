import AppKit

/// Draws the approved "Concept A" menu bar glyph (return arrow → drive) from
/// docs/design/menubar-icon.html, entirely via `NSBezierPath`/CoreGraphics — no SF Symbol, no
/// bitmap asset. This mirrors (in miniature) the app's own Dock icon, "so menu bar and Dock
/// read as the same product" (design card rationale for Concept A).
///
/// Geometry is the exact path data the design approved, in a 24x24 viewBox:
///   arrow shaft + corner: `M17.5 3v3.5a3 3 0 0 1-3 3H7.5`
///   arrowhead:            `M10 6.5 7 9.5l3 3`
///   drive slab:           `rect x=4 y=14.5 width=16 height=6 rx=1.6` (stroked, not filled)
///   LED:                  `circle cx=17.2 cy=17.5 r=0.9` (filled, no stroke)
/// stroke-width 1.8, round caps/joins, per the design card.
enum MenuBarIcon {
    /// Status-item icons are conventionally drawn at 18x18pt; `NSStatusItem`/AppKit handle the
    /// 2x Retina backing automatically when asked to draw an `NSImage` at this point size.
    static let pointSize: CGFloat = 18

    private static let viewBoxSize: CGFloat = 24

    /// - Parameter tint: `nil` renders a monochrome **template** image (`isTemplate = true`),
    ///   so AppKit recolors it to match the light/dark menu bar automatically — this is the
    ///   "plenty of space" (green) state. A non-nil tint bakes that actual color into the
    ///   image and marks it non-template, for the amber/red low-space warning states (a
    ///   status-item label frequently forces template/monochrome rendering on anything marked
    ///   as a template image, so real color requires *not* setting that flag).
    static func image(tint: NSColor?) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }

            let scale = pointSize / viewBoxSize
            context.scaleBy(x: scale, y: scale)

            let color = tint ?? NSColor.black
            color.setStroke()
            color.setFill()

            let lines = NSBezierPath()
            lines.lineWidth = 1.8
            lines.lineCapStyle = .round
            lines.lineJoinStyle = .round

            // Arrow shaft + rounded corner: "M17.5 3v3.5a3 3 0 0 1-3 3H7.5"
            lines.move(to: NSPoint(x: 17.5, y: 3))
            lines.line(to: NSPoint(x: 17.5, y: 6.5))
            lines.appendArc(withCenter: NSPoint(x: 14.5, y: 6.5), radius: 3,
                             startAngle: 0, endAngle: 90, clockwise: false)
            lines.line(to: NSPoint(x: 7.5, y: 9.5))

            // Arrowhead: "M10 6.5 7 9.5l3 3"
            lines.move(to: NSPoint(x: 10, y: 6.5))
            lines.line(to: NSPoint(x: 7, y: 9.5))
            lines.line(to: NSPoint(x: 10, y: 12.5))

            // Drive slab: rect x=4 y=14.5 w=16 h=6 rx=1.6 — stroked outline, not filled.
            lines.append(NSBezierPath(roundedRect: NSRect(x: 4, y: 14.5, width: 16, height: 6),
                                       xRadius: 1.6, yRadius: 1.6))
            lines.stroke()

            // LED dot: circle (17.2, 17.5) r=0.9 — filled, no stroke.
            let led = NSBezierPath(ovalIn: NSRect(x: 17.2 - 0.9, y: 17.5 - 0.9, width: 1.8, height: 1.8))
            led.fill()

            return true
        }
        image.isTemplate = (tint == nil)
        return image
    }
}
