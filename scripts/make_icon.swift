// Renders the app icon from FaceID's own face drawing (Sources/FaceID/Views/FaceMark.swift), the one the menu bar icon
// draws, so the two always match. It writes the Icon Composer package Resources/AppIcon.icon: a solid black fill in
// icon.json and one layer, Assets/mark.svg, the mark in white lines, with no glass, shadow, specular highlights or
// translucency, so the icon stays flat and black and white like the other apps of the family. It also writes
// Resources/AppIcon-1024.png for the README, the black body as a squircle with the mark on it, and
// Resources/AppIconGreen.png, the classic green icon (a systemGreen body, the same white mark) that FaceID puts on its
// bundle as a custom icon when the user picks it in the settings (Sources/FaceID/AppIcon.swift).
// Run from the repository root (FaceMark.swift needs only CoreGraphics, so it compiles alongside):
//   swiftc -O -o build/make_icon Sources/FaceID/Views/FaceMark.swift scripts/make_icon.swift && build/make_icon
import AppKit

@main
enum MakeIcon {
    /// The colour of the lines: white, as on the other icons of the family.
    static let ink = (red: 255, green: 255, blue: 255)
    /// The bodies: black, and for the classic icon Apple's systemGreen (#34C759), as the Face ID icon on iPhone.
    static let black = (red: 0, green: 0, blue: 0)
    static let green = (red: 52, green: 199, blue: 89)
    /// The mark's side as a share of the tile: as large as the family's icons are, 80 %, with the corners' bends well
    /// inside the tile's rounded corners.
    static let share: CGFloat = 0.8
    /// The line widths: as in that glyph, thinner than the menu bar's.
    static let lines = FaceMark.Lines.icon

    static let package = URL(fileURLWithPath: "Resources/AppIcon.icon")
    static let preview = URL(fileURLWithPath: "Resources/AppIcon-1024.png")
    static let classic = URL(fileURLWithPath: "Resources/AppIconGreen.png")

    static func main() {
        do {
            // In the Icon Composer format the 1024 canvas is the whole tile: the system cuts the squircle and leaves
            // the margins itself.
            try? FileManager.default.removeItem(at: package)
            try FileManager.default.createDirectory(at: package.appendingPathComponent("Assets"), withIntermediateDirectories: true)
            try svg(on: 1024).write(to: package.appendingPathComponent("Assets/mark.svg"), atomically: true, encoding: .utf8)
            try iconJSON.write(to: package.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
            // The README's picture and the green icon: the body at 100...924 of 1024, as macOS draws an icon, with the
            // mark taking the same share of it as of the tile. A custom icon is shown as it is drawn, mask and margins
            // included.
            let body = CGRect(x: 100, y: 100, width: 824, height: 824)
            try png(body: body, fill: black).write(to: preview)
            try png(body: body, fill: green).write(to: classic)
        } catch {
            FileHandle.standardError.write(Data("make_icon: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        let scale = share * 1024 / FaceMark.side
        print(String(format: "Resources/AppIcon.icon, AppIcon-1024.png, AppIconGreen.png: the mark %.1f px of the 1024 tile, lines %.1f px "
                     + "(corners), %.1f (eyes), %.1f (nose, smile)", share * 1024, lines.corner * scale, lines.eye * scale,
                     lines.face * scale))
    }

    /// The mark's parts on a square of `tile` points, centred, y down.
    static func parts(on tile: CGFloat) -> [CGPath] {
        let side = share * tile
        var transform = CGAffineTransform(translationX: (tile - side) / 2, y: (tile - side) / 2)
            .scaledBy(x: side / FaceMark.side, y: side / FaceMark.side)
        return (FaceMark.corners(lines: lines) + FaceMark.face(lines: lines)).compactMap { $0.copy(using: &transform) }
    }

    /// The layer: one filled path per part, on the 1024 × 1024 canvas (y down, as the shapes are).
    static func svg(on tile: CGFloat) -> String {
        let fill = String(format: "#%02X%02X%02X", ink.red, ink.green, ink.blue)
        func number(_ value: CGFloat) -> String { String(format: "%.2f", value) }
        let paths = parts(on: tile).map { part -> String in
            var d: [String] = []
            part.applyWithBlock { pointer in
                let element = pointer.pointee
                func point(_ index: Int) -> String { "\(number(element.points[index].x)) \(number(element.points[index].y))" }
                switch element.type {
                case .moveToPoint: d.append("M \(point(0))")
                case .addLineToPoint: d.append("L \(point(0))")
                case .addQuadCurveToPoint: d.append("Q \(point(0)) \(point(1))")
                case .addCurveToPoint: d.append("C \(point(0)) \(point(1)) \(point(2))")
                case .closeSubpath: d.append("Z")
                @unknown default: break
                }
            }
            return "  <path d=\"\(d.joined(separator: " "))\" fill=\"\(fill)\"/>"
        }
        let size = Int(tile)
        return (["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(size)\" height=\"\(size)\" viewBox=\"0 0 \(size) \(size)\">"]
                + paths + ["</svg>", ""]).joined(separator: "\n")
    }

    static let iconJSON = """
    {
      "fill" : {
        "solid" : "srgb:0.00000,0.00000,0.00000,1.00000"
      },
      "groups" : [
        {
          "layers" : [
            {
              "glass" : false,
              "image-name" : "mark.svg",
              "name" : "mark"
            }
          ],
          "shadow" : {
            "kind" : "none",
            "opacity" : 0
          },
          "specular" : false,
          "translucency" : {
            "enabled" : false,
            "value" : 0
          }
        }
      ],
      "supported-platforms" : {
        "squares" : [
          "macOS"
        ]
      }
    }

    """

    /// The whole icon on a transparent 1024 canvas: the body in `body`, filled with `fill`, and the mark on it.
    static func png(body: CGRect, fill: (red: Int, green: Int, blue: Int)) throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.addPath(squircle(body))
        ctx.setFillColor(CGColor(colorSpace: space, components: [fill.red, fill.green, fill.blue].map { CGFloat($0) / 255 } + [1])!)
        ctx.fillPath()
        // y down, like the mark.
        ctx.translateBy(x: body.minX, y: 1024 - body.minY)
        ctx.scaleBy(x: 1, y: -1)
        for part in parts(on: body.width) { ctx.addPath(part) }
        let rgb = [ink.red, ink.green, ink.blue].map { CGFloat($0) / 255 }
        ctx.setFillColor(CGColor(colorSpace: space, components: rgb + [1])!)
        ctx.fillPath()
        guard let data = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    /// The body's outline: Apple-style continuous corners (a superellipse), as the other apps of the family draw it.
    static func squircle(_ rect: CGRect, exponent: CGFloat = 5) -> CGPath {
        let path = CGMutablePath()
        let a = rect.width / 2, b = rect.height / 2
        for i in 0...720 {
            let t = CGFloat(i) / 720 * 2 * .pi
            let c = cos(t), s = sin(t)
            let point = CGPoint(x: rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent),
                                y: rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
