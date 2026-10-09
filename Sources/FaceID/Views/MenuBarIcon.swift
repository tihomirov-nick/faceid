import AppKit
import FaceCore

/// FaceID's icon in the menu bar: FaceID's own face (`FaceMark`, the same drawing as the app icon's mark) as a template
/// image that takes the menu bar's own color: the 14.34 pt mark on a 15 × 16 pt canvas. At rest it is `image(Frame())` and
/// no timer runs. It moves only at the moments that matter: while a face is being checked the face dims and a scan
/// line runs between the corners, when the face is recognized a checkmark draws itself in its place, and when it is not
/// the face shakes "no" inside the corners. With Reduce Motion the states change at once.
@MainActor
final class MenuBarIcon {
    enum Moment {
        case idle
        /// A face is being checked: lasts until the next moment.
        case scanning
        case success
        case failure
    }

    /// One frame of the glyph.
    struct Frame: Equatable {
        /// Opacity of the face: the eyes, the nose and the smile.
        var face: CGFloat = 1
        /// Sideways offset of the face inside the corners (the head shake).
        var shake: CGFloat = 0
        /// Height of the scan line from the top of its run, 0...1; nil without one.
        var scan: CGFloat?
        /// How much of the checkmark is drawn, 0...1, and how opaque it is.
        var check: CGFloat = 0
        var checkOpacity: CGFloat = 1
    }

    /// Sets the image on the status item's button.
    var onFrame: (NSImage) -> Void = { _ in }

    private var moment = Moment.idle
    private var started: CFTimeInterval = 0
    private var timer: Timer?
    private var hold: DispatchWorkItem?

    static let successLength: CFTimeInterval = 1.25
    static let failureLength: CFTimeInterval = 0.55

    var still: NSImage { Self.image(Frame()) }

    func play(_ moment: Moment) {
        self.moment = moment
        started = CACurrentMediaTime()
        hold?.cancel()
        hold = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // No movement: each state is shown at once, the checkmark for a moment.
            stopTimer()
            switch moment {
            case .scanning: onFrame(Self.image(Frame(face: 0.45)))
            case .success: showFor(0.8, Self.image(Frame(face: 0, check: 1)))
            case .idle, .failure: onFrame(still)
            }
            return
        }
        guard moment != .idle else {
            stopTimer()
            onFrame(still)
            return
        }
        if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            // Common modes: it keeps moving while a menu is open.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        tick()
    }

    private func showFor(_ seconds: TimeInterval, _ image: NSImage) {
        onFrame(image)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.moment = .idle
                self.onFrame(self.still)
            }
        }
        hold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let t = CACurrentMediaTime() - started
        guard let frame = Self.frame(moment, at: t) else {
            moment = .idle
            stopTimer()
            onFrame(still)
            return
        }
        onFrame(Self.image(frame))
    }

    /// The frame `t` seconds into `moment`; nil once it is over.
    static func frame(_ moment: Moment, at t: CFTimeInterval) -> Frame? {
        func ease(_ x: Double) -> CGFloat { let x = min(1, max(0, x)); return CGFloat(x * x * (3 - 2 * x)) }
        switch moment {
        case .idle:
            return nil
        case .scanning:
            // Down and up again, slowing at the ends, while the face is dimmed.
            let phase = t.truncatingRemainder(dividingBy: 2.2) / 1.1
            return Frame(face: 0.45, scan: ease(phase <= 1 ? phase : 2 - phase))
        case .success:
            // The face fades, the checkmark draws itself, stays, and gives way to the face again.
            guard t < successLength else { return nil }
            let face = t < 0.15 ? 1 - ease(t / 0.15) : (t > 1.05 ? ease((t - 1.05) / 0.2) : 0)
            return Frame(face: face, check: ease((t - 0.1) / 0.3), checkOpacity: t > 1.05 ? 1 - ease((t - 1.05) / 0.2) : 1)
        case .failure:
            // "No": the face turns left and right inside the corners, like the glyph in the island.
            guard t < failureLength else { return nil }
            let keys: [(Double, CGFloat)] = [(0, 0), (0.08, -1.5), (0.18, 1.5), (0.28, -1.1), (0.38, 0.7), (0.55, 0)]
            var shake: CGFloat = 0
            for (a, b) in zip(keys, keys.dropFirst()) where t >= a.0 && t <= b.0 {
                shake = a.1 + (b.1 - a.1) * ease((t - a.0) / (b.0 - a.0))
            }
            return Frame(shake: shake)
        }
    }

    // MARK: - Drawing

    /// The canvas, in points. The status item is `variableLength`: as wide as the image plus the menu bar's own margins.
    /// 15 pt is the width of the menu bar icons of all four apps of the family, so the gaps between them are the same.
    nonisolated static let size = NSSize(width: 15, height: 16)

    /// The mark's top left corner on a canvas drawn at `scale` pixels per point: 1 pt from the top, and across as close
    /// to the middle as whole pixels allow (0.5 pt at 2x, 0 at 1x), so the outer edges of the top and left corners are
    /// crisp and the 14.34 pt mark covers 29 pixels at 2x, 14.5 pt as measured in the menu bar, like the SF Symbol before it.
    nonisolated static func origin(scale: CGFloat) -> CGPoint {
        let middle = (size.width - FaceMark.side) / 2
        guard scale > 0 else { return CGPoint(x: middle, y: 1) }
        return CGPoint(x: (middle * scale).rounded() / scale, y: 1)
    }

    /// The icon for `frame` as a template image; `Frame()` is the icon at rest.
    nonisolated static func image(_ frame: Frame) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The image is drawn once for each pixel density, so the mark lands on whole pixels at 1x and at 2x.
            let origin = origin(scale: abs(context.userSpaceToDeviceSpaceTransform.a))
            FaceMark.draw(in: context, at: origin, faceOpacity: frame.face, shake: frame.shake)
            let center = CGPoint(x: origin.x + FaceMark.center.x, y: origin.y + FaceMark.center.y)
            // The scan line and the checkmark are as thick as the corners.
            context.setLineWidth(FaceMark.Lines.regular.corner)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            // The scan line, between the corners.
            if let scan = frame.scan {
                let y = center.y - 4.6 + 9.2 * scan
                context.setStrokeColor(CGColor(gray: 0, alpha: 1))
                context.move(to: CGPoint(x: center.x - 4.75, y: y))
                context.addLine(to: CGPoint(x: center.x + 4.75, y: y))
                context.strokePath()
            }
            // The checkmark in place of the face, drawn from its start.
            if frame.check > 0, frame.checkOpacity > 0 {
                let points = [CGPoint(x: center.x - 3.45, y: center.y + 0.35), CGPoint(x: center.x - 0.92, y: center.y + 2.88),
                              CGPoint(x: center.x + 3.57, y: center.y - 2.65)]
                let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
                var left = lengths.reduce(0, +) * frame.check
                context.setStrokeColor(CGColor(gray: 0, alpha: frame.checkOpacity))
                context.move(to: points[0])
                for (index, length) in lengths.enumerated() where left > 0 {
                    let a = points[index], b = points[index + 1], part = min(1, left / length)
                    context.addLine(to: CGPoint(x: a.x + (b.x - a.x) * part, y: a.y + (b.y - a.y) * part))
                    left -= length
                }
                context.strokePath()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "FaceID"
        return image
    }
}

#if DEBUG
extension MenuBarIcon {
    /// Debug hooks: the icon on a dark and a light menu bar, at 8 times the size (at rest, scanning, the checkmark, the
    /// head shake) and at its real size in 1x and 2x pixels.
    static func debugSheet(to path: String) {
        let frames = [Frame(), Frame(face: 0.45, scan: 0.35), Frame(face: 0, check: 1), Frame(shake: -1.5)]
        let zoom: CGFloat = 8, cell = size.width * zoom + 20, rowHeight = size.height * zoom + 32, natural: CGFloat = 110
        let width = CGFloat(frames.count) * cell + natural + 20, height = 2 * rowHeight
        let bounds = NSRect(origin: .zero, size: size)
        /// `image` in `color` at `scale` pixels per point.
        func tinted(_ image: NSImage, _ color: NSColor, scale: CGFloat) -> NSImage {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
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
            for (index, frame) in frames.enumerated() {
                tinted(image(frame), ink, scale: zoom)
                    .draw(in: NSRect(x: CGFloat(index) * cell + 10, y: y + 22, width: size.width * zoom, height: size.height * zoom))
            }
            let x = CGFloat(frames.count) * cell + 10
            tinted(image(Frame()), ink, scale: 1).draw(in: NSRect(x: x, y: y + 70, width: size.width, height: size.height))
            tinted(image(Frame()), ink, scale: 2)
                .draw(in: NSRect(x: x + 34, y: y + 62, width: size.width * 2, height: size.height * 2))
            ("×8: rest, scan, check, shake · 1x, 2x" as NSString)
                .draw(at: NSPoint(x: 10, y: y + 4), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: ink.withAlphaComponent(0.6)])
        }
        NSGraphicsContext.restoreGraphicsState()
        try? sheet.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        Log.write("menu bar sheet: \(path)")
    }
}
#endif
