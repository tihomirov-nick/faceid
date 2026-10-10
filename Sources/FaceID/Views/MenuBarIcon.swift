import AppKit
import FaceCore

/// FaceID's icon in the menu bar: FaceID's own face (`FaceMark`, the same drawing as the app icon's mark) as a template
/// image that takes the menu bar's own color. It never moves: how a face check goes, the island shows. It is as big as
/// the menu bar's own icons (Wi-Fi, Control Center, the input source): the 16 pt mark in the middle of a 22 pt canvas (the
/// 24 pt menu bar's own height is the frame of its items), its lines as heavy against its size as before, they scale with
/// the mark (`FaceMark.Lines.regular`).
enum MenuBarIcon {
    /// The mark's side, in points: about 16 pt high and at most 20 pt wide, like the system icons.
    static let markSide: CGFloat = 16

    /// The canvas, in points: 22 pt high, and as wide as the square mark plus 1 pt on each side. The status item is
    /// `variableLength`: as wide as the image plus the menu bar's own margins.
    static let size = NSSize(width: 18, height: 22)

    /// The mark's top left corner on a canvas drawn at `scale` pixels per point: in the middle, on whole pixels, so the
    /// outer edges of the corners are crisp at 1x and at 2x.
    static func origin(scale: CGFloat) -> CGPoint {
        let middle = CGPoint(x: (size.width - markSide) / 2, y: (size.height - markSide) / 2)
        guard scale > 0 else { return middle }
        return CGPoint(x: (middle.x * scale).rounded() / scale, y: (middle.y * scale).rounded() / scale)
    }

    /// The icon, a template image.
    static let image: NSImage = {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The image is drawn once for each pixel density.
            FaceMark.draw(in: context, at: origin(scale: abs(context.userSpaceToDeviceSpaceTransform.a)), size: markSide)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "FaceID"
        return image
    }()
}

#if DEBUG
extension MenuBarIcon {
    /// `image` in `color` at `scale` pixels per point, as the menu bar tints a template image.
    static func tinted(_ color: NSColor, scale: CGFloat) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        let bounds = NSRect(origin: .zero, size: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: bounds)
        color.set()
        bounds.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: NSSize(width: size.width * scale, height: size.height * scale))
        result.addRepresentation(rep)
        return result
    }

    /// Debug hooks: the icon on a dark and a light menu bar, at 8 times the size (the canvas outlined) and at its real
    /// size in 1x and 2x pixels.
    static func debugSheet(to path: String) {
        let zoom: CGFloat = 8, rowHeight = size.height * zoom + 32, width = size.width * zoom + 140, height = 2 * rowHeight
        let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)!
        sheet.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        NSGraphicsContext.current?.imageInterpolation = .none
        for (row, dark) in [true, false].enumerated() {
            let y = height - CGFloat(row + 1) * rowHeight
            (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(x: 0, y: y, width: width, height: rowHeight).fill()
            let ink = dark ? NSColor.white : NSColor.black
            let large = NSRect(x: 10, y: y + 22, width: size.width * zoom, height: size.height * zoom)
            ink.withAlphaComponent(0.25).setStroke()
            NSBezierPath(rect: large.insetBy(dx: -0.5, dy: -0.5)).stroke()
            tinted(ink, scale: zoom).draw(in: large)
            let x = large.maxX + 20
            tinted(ink, scale: 1).draw(in: NSRect(x: x, y: y + 90, width: size.width, height: size.height))
            tinted(ink, scale: 2).draw(in: NSRect(x: x + 40, y: y + 80, width: size.width * 2, height: size.height * 2))
            ("×8 (22 pt canvas) · 1x, 2x" as NSString)
                .draw(at: NSPoint(x: 10, y: y + 4), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: ink.withAlphaComponent(0.6)])
        }
        NSGraphicsContext.restoreGraphicsState()
        try? sheet.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
