import AppKit

/// The menu bar icon: the app icon's two shapes (Shed.svg and Body.svg), an old skin left open as six faint segments and the new one
/// coming out of its gap, drawn as a template image so it takes the menu bar's color. While something is being cleaned the old skin's
/// segments breathe one after another, as a tile's chart does while it loads (`LoadingWave`); `StatusItemController` plays it, and
/// when the cleanup ends the icon rests.
enum MenuBarIcon {
    static let frameRate: Double = 30

    // MARK: Drawing

    /// The segments in the order they leave and come back: clockwise from the gap.
    static let order = Array(0..<6)

    /// How much of segment `rank` (its place in `order`) shows at `date` while the icon breathes: the charts' loading wave
    /// (`LoadingWave.opacity`), the same pace and the same spread over the segments. nil: at rest, every segment full.
    static func visibility(rank: Int, at date: Date?) -> Double {
        guard let date else { return 1 }
        return LoadingWave.opacity(date, index: rank, count: order.count, loading: true, reduceMotion: false)
    }

    /// The shapes in the design's 1024 × 1024 canvas, as the icon's SVGs draw them: the old skin, a ring open toward the lower
    /// right, and the new body, a disc in that gap.
    static let shedCentre = CGPoint(x: 457, y: 457)
    static let outerRadius: CGFloat = 300
    static let innerRadius: CGFloat = 245
    /// Where the ring is open, degrees clockwise from the top, and how wide.
    static let gapCentre: CGFloat = 135
    static let gapWidth: CGFloat = 60
    static let gapDegrees: CGFloat = 6
    static let shedAlpha: CGFloat = 0.45
    static let bodyCentre = CGPoint(x: 627, y: 627)
    static let bodyRadius: CGFloat = 230
    /// The part of the canvas the shapes fill, so they fill the menu bar's square.
    static let artBounds = CGRect(x: 157, y: 157, width: 700, height: 700)
    static let pointSize = NSSize(width: 18, height: 18)

    static func image(at date: Date?) -> NSImage {
        let image = NSImage(size: pointSize, flipped: true) { bounds in
            let scale = min(bounds.width, bounds.height) / artBounds.width
            func point(_ p: CGPoint) -> CGPoint {
                CGPoint(x: bounds.minX + (p.x - artBounds.minX) * scale, y: bounds.minY + (p.y - artBounds.minY) * scale)
            }
            let centre = point(shedCentre)
            let count = order.count
            let span = 360 - gapWidth
            let first = gapCentre + gapWidth / 2
            for index in 0..<count {
                let shown = CGFloat(visibility(rank: order.firstIndex(of: index) ?? index, at: date))
                // Degrees clockwise from the top; the image is flipped, so AppKit's counterclockwise is clockwise on screen.
                let start = -90 + first + CGFloat(index) * span / CGFloat(count) + gapDegrees / 2
                let end = -90 + first + CGFloat(index + 1) * span / CGFloat(count) - gapDegrees / 2
                let path = NSBezierPath()
                path.appendArc(withCenter: centre, radius: outerRadius * scale, startAngle: start, endAngle: end, clockwise: false)
                path.appendArc(withCenter: centre, radius: innerRadius * scale, startAngle: end, endAngle: start, clockwise: true)
                path.close()
                NSColor.black.withAlphaComponent(shedAlpha * shown).setFill()
                path.fill()
            }
            let body = point(bodyCentre), radius = bodyRadius * scale
            NSColor.black.setFill()
            NSBezierPath(ovalIn: CGRect(x: body.x - radius, y: body.y - radius, width: 2 * radius, height: 2 * radius)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
