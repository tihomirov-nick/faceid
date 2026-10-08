// Writes the mark of the app icon from FaceID's own face drawing (Sources/FaceID/Views/FaceMark.swift), the same one
// the menu bar icon draws, so the two always match: the two layers of Resources/AppIcon.icon, Assets/frame.svg (the
// corners) and Assets/face.svg (the eyes, the nose and the smile), white. The mark is scaled as a whole, line widths
// included, into the square the previous mark took on the layer canvas (243.6...780.4 of 1024, the canvas being the
// icon's tile), so the icon keeps its size. icon.json (fill, glass, shadow, translucency, opacity) is not touched.
// Run from the repository root (FaceMark.swift needs only CoreGraphics, so it compiles alongside):
//   swiftc -O -o build/make_icon_face Sources/FaceID/Views/FaceMark.swift scripts/make_icon_face.swift && build/make_icon_face
import CoreGraphics
import Foundation

@main
enum MakeIconFace {
    /// The previous mark's corners on the layer canvas, outer edges of the lines.
    static let square = (low: CGFloat(243.6), high: CGFloat(780.4))
    static let assets = URL(fileURLWithPath: "Resources/AppIcon.icon/Assets")

    static func main() {
        let scale = (square.high - square.low) / FaceMark.side
        let transform = CGAffineTransform(translationX: square.low, y: square.low).scaledBy(x: scale, y: scale)
        write(FaceMark.corners(), to: "frame.svg", transform)
        write(FaceMark.face(), to: "face.svg", transform)
        print(String(format: "frame.svg, face.svg: the mark spans %.1f…%.1f of 1024, lines %.1f px (corners), %.1f (eyes), %.1f (nose, smile)",
                     square.low, square.high, FaceMark.Lines.regular.corner * scale, FaceMark.Lines.regular.eye * scale,
                     FaceMark.Lines.regular.face * scale))
    }

    /// One filled path per part, in the layer's coordinates (1024 × 1024, y down, as the shapes are).
    static func write(_ parts: [CGPath], to name: String, _ transform: CGAffineTransform) {
        func number(_ value: CGFloat) -> String { String(format: "%.2f", value) }
        let paths = parts.map { part -> String in
            var d: [String] = []
            part.applyWithBlock { pointer in
                let element = pointer.pointee
                func point(_ index: Int) -> String {
                    let p = element.points[index].applying(transform)
                    return "\(number(p.x)) \(number(p.y))"
                }
                switch element.type {
                case .moveToPoint: d.append("M \(point(0))")
                case .addLineToPoint: d.append("L \(point(0))")
                case .addQuadCurveToPoint: d.append("Q \(point(0)) \(point(1))")
                case .addCurveToPoint: d.append("C \(point(0)) \(point(1)) \(point(2))")
                case .closeSubpath: d.append("Z")
                @unknown default: break
                }
            }
            return "  <path d=\"\(d.joined(separator: " "))\" fill=\"#FFFFFF\"/>"
        }
        let svg = ["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">"] + paths + ["</svg>", ""]
        do {
            try svg.joined(separator: "\n").write(to: assets.appendingPathComponent(name), atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("make_icon_face: cannot write \(name): \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
