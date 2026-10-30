import AppKit

/// The menu bar icon: the app icon's storage ring (Used.svg and Free.svg), nine segments around a sparkle (Spark.svg), drawn as a
/// template image so it takes the menu bar's color. The last two segments are the free space, drawn faint. While something is being
/// cleaned the segments breathe one after another around the ring, as a tile's chart does while it loads (`LoadingWave`);
/// `StatusItemController` plays it, and when the cleanup ends the icon rests.
enum MenuBarIcon {
    static let frameRate: Double = 30

    // MARK: Drawing

    /// The segments in the order they leave and come back: clockwise from the top.
    static let order = Array(0..<9)

    /// How much of segment `rank` (its place in `order`) shows at `date` while the icon breathes: the charts' loading wave
    /// (`LoadingWave.opacity`), the same pace and the same spread over the nine segments. nil: at rest, every segment full.
    static func visibility(rank: Int, at date: Date?) -> Double {
        guard let date else { return 1 }
        return LoadingWave.opacity(date, index: rank, count: order.count, loading: true, reduceMotion: false)
    }

    /// The ring in the design's 1024 × 1024 canvas: nine segments with a small gap between them, the last `freeCount` faint.
    static let outerRadius: CGFloat = 400
    static let innerRadius: CGFloat = 270
    static let gapDegrees: CGFloat = 7
    static let freeCount = 2
    static let freeAlpha: CGFloat = 0.35
    /// The sparkle in the middle: a four-pointed star, this far from the centre to each point.
    static let sparkRadius: CGFloat = 150
    static let pointSize = NSSize(width: 18, height: 18)

    static func image(at date: Date?) -> NSImage {
        let image = NSImage(size: pointSize, flipped: true) { bounds in
            let scale = min(bounds.width, bounds.height) / (2 * outerRadius)
            let centre = CGPoint(x: bounds.midX, y: bounds.midY)
            let count = order.count
            for index in 0..<count {
                let shown = CGFloat(visibility(rank: order.firstIndex(of: index) ?? index, at: date))
                let base: CGFloat = index >= count - freeCount ? freeAlpha : 1
                // Degrees clockwise from the top; the image is flipped, so AppKit's counterclockwise is clockwise on screen.
                let start = -90 + CGFloat(index) * 360 / CGFloat(count) + gapDegrees / 2
                let end = -90 + CGFloat(index + 1) * 360 / CGFloat(count) - gapDegrees / 2
                let path = NSBezierPath()
                path.appendArc(withCenter: centre, radius: outerRadius * scale, startAngle: start, endAngle: end, clockwise: false)
                path.appendArc(withCenter: centre, radius: innerRadius * scale, startAngle: end, endAngle: start, clockwise: true)
                path.close()
                NSColor.black.withAlphaComponent(base * shown).setFill()
                path.fill()
            }
            sparkle(centre: centre, radius: sparkRadius * scale).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// A four-pointed star with curved sides, as Spark.svg draws it.
    static func sparkle(centre c: CGPoint, radius r: CGFloat) -> NSBezierPath {
        let w = r * 0.25
        let path = NSBezierPath()
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.curve(to: CGPoint(x: c.x + r, y: c.y), controlPoint1: CGPoint(x: c.x + w * 0.35, y: c.y - w), controlPoint2: CGPoint(x: c.x + w, y: c.y - w * 0.35))
        path.curve(to: CGPoint(x: c.x, y: c.y + r), controlPoint1: CGPoint(x: c.x + w, y: c.y + w * 0.35), controlPoint2: CGPoint(x: c.x + w * 0.35, y: c.y + w))
        path.curve(to: CGPoint(x: c.x - r, y: c.y), controlPoint1: CGPoint(x: c.x - w * 0.35, y: c.y + w), controlPoint2: CGPoint(x: c.x - w, y: c.y + w * 0.35))
        path.curve(to: CGPoint(x: c.x, y: c.y - r), controlPoint1: CGPoint(x: c.x - w, y: c.y - w * 0.35), controlPoint2: CGPoint(x: c.x - w * 0.35, y: c.y - w))
        path.close()
        NSColor.black.setFill()
        return path
    }
}
