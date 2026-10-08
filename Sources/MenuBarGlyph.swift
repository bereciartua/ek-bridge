import AppKit

/// The menu bar icon: the app icon's day arc (Resources/make_icon.swift, the
/// small variant) as an 18 pt template image, in three states. Which one
/// shows is `MenuBarGlyphState.for(needsAttention:bridgeOn:)`.
///
/// The 1024 pt canvas is scaled by 0.02 and moved so the drawing sits in the
/// middle of the 18 pt box: horizon at y 660 → 6 pt (measured from the
/// bottom), arc radius 300 → 6 pt around (9, 6), sun at 128°, dots at 20°,
/// 54° and 88°. The horizon is 2 pt wide with its edges on whole points (5
/// and 7), so it's crisp at 1× and 2×; the arc is 1.6 pt, a little lighter,
/// as in the icon.
enum MenuBarGlyph {
    static let size = NSSize(width: 18, height: 18)

    private static let center = NSPoint(x: 9, y: 6)
    private static let radius: CGFloat = 6
    private static let horizonWidth: CGFloat = 2
    private static let pathWidth: CGFloat = 1.6
    private static let sunAngle: CGFloat = 128
    private static let sunRadius: CGFloat = 2.5
    private static let dotRadius: CGFloat = 0.9
    /// The transparent ring around the sun and the badges.
    private static let gap: CGFloat = 1

    static func image(_ state: MenuBarGlyphState) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(state)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func onArc(_ degrees: CGFloat) -> NSPoint {
        let angle = degrees * .pi / 180
        return NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    private static func circle(_ point: NSPoint, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius,
                                    width: radius * 2, height: radius * 2))
    }

    private static func draw(_ state: MenuBarGlyphState) {
        guard let context = NSGraphicsContext.current else { return }
        // Paused: the same drawing, faded as one layer, so overlaps don't
        // show darker.
        let cg = context.cgContext
        cg.saveGState()
        if state == .paused { cg.setAlpha(0.45) }
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        NSColor.black.setStroke()
        NSColor.black.setFill()

        // The horizon, then the part of the day already gone, from sunrise
        // to the sun.
        let horizon = NSBezierPath()
        horizon.move(to: NSPoint(x: 2, y: center.y))
        horizon.line(to: NSPoint(x: 16, y: center.y))
        horizon.lineWidth = horizonWidth
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: 180, endAngle: sunAngle, clockwise: true)
        path.lineWidth = pathWidth
        for line in [horizon, path] {
            line.lineCapStyle = .round
            line.stroke()
        }
        // The rest of the day.
        for degrees: CGFloat in [20, 54, 88] {
            circle(onArc(degrees), dotRadius).fill()
        }

        // The sun, with a clear ring that stops the arc short of it.
        let sun = onArc(sunAngle)
        clear(circle(sun, sunRadius + gap), in: context)
        circle(sun, sunRadius).fill()
        cg.endTransparencyLayer()
        cg.restoreGState()

        NSColor.black.setFill()
        switch state {
        case .on:
            break
        case .paused:
            // Two bars at the top right.
            let bars = [NSRect(x: 13, y: 13, width: 1.5, height: 5),
                        NSRect(x: 16, y: 13, width: 1.5, height: 5)]
            clear(NSBezierPath(rect: NSRect(x: 12, y: 12, width: 6, height: 6)), in: context)
            for bar in bars { NSBezierPath(roundedRect: bar, xRadius: 0.7, yRadius: 0.7).fill() }
        case .attention:
            // A 4.5 pt dot at the top right.
            let badge = NSPoint(x: 15.5, y: 15.25)
            clear(circle(badge, 2.25 + gap), in: context)
            circle(badge, 2.25).fill()
        }
    }

    private static func clear(_ shape: NSBezierPath, in context: NSGraphicsContext) {
        context.saveGraphicsState()
        context.compositingOperation = .clear
        shape.fill()
        context.restoreGraphicsState()
    }
}
