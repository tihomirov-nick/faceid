import CoreGraphics

/// FaceID's face, drawn by its own geometry: four corners, two eyes, a nose and a smile, built from lines and circular
/// arcs. One drawing serves the whole app: the menu bar icon (`MenuBarIcon`), the island's glyph (`FaceMarkView`) and the
/// mark of the app icon (`scripts/make_icon.swift` writes it into Resources/AppIcon.icon). It uses only CoreGraphics: the
/// script compiles this file on its own.
///
/// The geometry is laid out in units on a mark of `side` units (the menu bar's size in points before the family's icons
/// grew), y down from its top left corner; the corners' outer edges lie on the sides of the square. Every size scales it
/// as a whole, the lines with it. The numbers follow the large Face ID glyph the app icon was asked to look like: this
/// very construction, fitted to a picture of it, matches it within a fraction of a pixel. Only the weight of the lines
/// differs between the uses, see `Lines`.
enum FaceMark {
    static let side: CGFloat = 14.34

    /// Line widths on a mark of `side` units.
    struct Lines {
        var corner: CGFloat
        var eye: CGFloat
        var face: CGFloat
        /// As the SF Symbol `faceid` at regular weight, which the menu bar used: the menu bar icon, where thinner lines
        /// would fade (1.32 pt corners on its 16 pt mark).
        static let regular = Lines(corner: 1.18, eye: 1.13, face: 0.95)
        /// As the symbol at light weight, which the island used.
        static let light = Lines(corner: 0.925, eye: 0.895, face: 0.77)
        /// As the large glyph the app icon follows: thinner corners, the eyes the boldest lines.
        static let icon = Lines(corner: 0.9, eye: 1.16, face: 0.85)
    }

    /// The middle of the mark.
    static let center = CGPoint(x: side / 2, y: side / 2)

    /// The four corners on a mark of `size` points, each a filled shape: an L whose bend is a quarter circle, with round
    /// ends.
    static func corners(size: CGFloat = side, lines: Lines = .regular) -> [CGPath] {
        let inset = lines.corner / 2, radius: CGFloat = 2.78, reach: CGFloat = 3.86
        return [(false, false), (true, false), (false, true), (true, true)].map { right, bottom in
            // Laid out for the top left corner, mirrored for the others.
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: right ? side - x : x, y: bottom ? side - y : y)
            }
            let line = CGMutablePath()
            line.move(to: point(inset, reach))
            line.addArc(tangent1End: point(inset, inset), tangent2End: point(reach, inset), radius: radius)
            line.addLine(to: point(reach, inset))
            return stroked(line, width: lines.corner, size: size)
        }
    }

    /// The eyes, the nose and the smile on a mark of `size` points, each a filled shape.
    static func face(size: CGFloat = side, lines: Lines = .regular) -> [CGPath] {
        var parts: [CGPath] = []
        // The eyes: short upright capsules.
        for x in [center.x - 2.99, center.x + 2.99] {
            let eye = CGMutablePath()
            eye.move(to: CGPoint(x: x, y: 5.3))
            eye.addLine(to: CGPoint(x: x, y: 6.38))
            parts.append(stroked(eye, width: lines.eye, size: size))
        }
        // The nose: down from the eyes' line just right of the middle, a small bend, a short stroke to the left.
        let nose = CGMutablePath(), stem = center.x + 0.27, bend: CGFloat = 0.79, bottom: CGFloat = 8.61
        nose.move(to: CGPoint(x: stem, y: 5.19))
        nose.addLine(to: CGPoint(x: stem, y: bottom - bend))
        nose.addArc(center: CGPoint(x: stem - bend, y: bottom - bend), radius: bend, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        nose.addLine(to: CGPoint(x: stem - 0.98, y: bottom))
        parts.append(stroked(nose, width: lines.face, size: size))
        // The smile: a circular arc through its two ends and its lowest point.
        let half: CGFloat = 2.2, ends: CGFloat = 10.31, depth: CGFloat = 0.82
        let radius = (half * half + depth * depth) / (2 * depth)
        let middle = CGPoint(x: center.x, y: ends + depth - radius)
        let angle = atan2(ends - middle.y, half)
        let smile = CGMutablePath()
        smile.addArc(center: middle, radius: radius, startAngle: angle, endAngle: .pi - angle, clockwise: false)
        parts.append(stroked(smile, width: lines.face, size: size))
        return parts
    }

    /// Draws the menu bar's mark, `size` points wide, in black (as template images want it) with its top left corner at
    /// `origin`.
    static func draw(in context: CGContext, at origin: CGPoint, size: CGFloat) {
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for part in corners(size: size) + face(size: size) { context.addPath(part) }
        context.fillPath()
        context.restoreGState()
    }

    /// The line as a filled outline, scaled from the layout size to `size`.
    private static func stroked(_ path: CGPath, width: CGFloat, size: CGFloat) -> CGPath {
        let outline = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        guard size != side else { return outline }
        var scale = CGAffineTransform(scaleX: size / side, y: size / side)
        return outline.copy(using: &scale) ?? outline
    }
}
