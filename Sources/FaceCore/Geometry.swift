import CoreGraphics
import Foundation

/// The five points a face is aligned by, in image pixels with the origin at the top left: eye centers, nose tip
/// and mouth corners. "Left" and "right" are as seen in the image (the person's right eye is `leftEye`).
public struct FivePoints: Equatable, Codable, Sendable {
    public var leftEye: CGPoint
    public var rightEye: CGPoint
    public var nose: CGPoint
    public var mouthLeft: CGPoint
    public var mouthRight: CGPoint

    public init(leftEye: CGPoint, rightEye: CGPoint, nose: CGPoint, mouthLeft: CGPoint, mouthRight: CGPoint) {
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.nose = nose
        self.mouthLeft = mouthLeft
        self.mouthRight = mouthRight
    }

    public init(_ points: [CGPoint]) {
        precondition(points.count == 5)
        self.init(leftEye: points[0], rightEye: points[1], nose: points[2], mouthLeft: points[3], mouthRight: points[4])
    }

    public var array: [CGPoint] { [leftEye, rightEye, nose, mouthLeft, mouthRight] }

    /// Distance between the eye centers in pixels: the face size used by the quality checks.
    public var eyeDistance: Double { leftEye.distance(to: rightEye) }
}

/// 2×3 affine matrix: x' = a·x + b·y + tx, y' = c·x + d·y + ty.
public struct Affine: Equatable, Sendable {
    public var a, b, c, d, tx, ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public func apply(_ p: CGPoint) -> CGPoint {
        CGPoint(x: a * p.x + b * p.y + tx, y: c * p.x + d * p.y + ty)
    }

    public var inverted: Affine? {
        let det = a * d - b * c
        guard abs(det) > 1e-12 else { return nil }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return Affine(a: ia, b: ib, c: ic, d: id, tx: -(ia * tx + ib * ty), ty: -(ic * tx + id * ty))
    }

    /// Uniform scale of a similarity transform.
    public var scale: Double { (a * a + c * c).squareRoot() }
}

public enum FaceAlignment {
    /// Side of the aligned face image the recognition model takes.
    public static let size = 112

    /// Where the five points land in the 112×112 face image: the ArcFace template SFace was trained with
    /// (the same numbers as OpenCV FaceRecognizerSF::alignCrop).
    public static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// Least-squares similarity transform (rotation, uniform scale and shift, no mirroring) that moves `source`
    /// onto `target`. Equivalent to Umeyama's estimate used by OpenCV for non-degenerate faces.
    public static func similarity(from source: [CGPoint], to target: [CGPoint]) -> Affine {
        precondition(source.count == target.count && !source.isEmpty)
        let n = Double(source.count)
        let sx = source.reduce(0) { $0 + $1.x } / n, sy = source.reduce(0) { $0 + $1.y } / n
        let tx = target.reduce(0) { $0 + $1.x } / n, ty = target.reduce(0) { $0 + $1.y } / n
        // In complex numbers: target ≈ z·source with z = Σ conj(p)·q / Σ |p|².
        var re = 0.0, im = 0.0, norm = 0.0
        for (p, q) in zip(source, target) {
            let px = p.x - sx, py = p.y - sy, qx = q.x - tx, qy = q.y - ty
            re += px * qx + py * qy
            im += px * qy - py * qx
            norm += px * px + py * py
        }
        guard norm > 1e-12 else { return Affine(a: 1, b: 0, c: 0, d: 1, tx: tx - sx, ty: ty - sy) }
        let a = re / norm, b = im / norm
        return Affine(a: a, b: -b, c: b, d: a, tx: tx - (a * sx - b * sy), ty: ty - (b * sx + a * sy))
    }

    /// Transform from image pixels to the 112×112 aligned face.
    public static func transform(for points: FivePoints) -> Affine {
        similarity(from: points.array, to: template)
    }
}

extension CGPoint {
    public func distance(to other: CGPoint) -> Double {
        ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).squareRoot()
    }

    static func mean(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let n = CGFloat(points.count)
        return CGPoint(x: points.reduce(0) { $0 + $1.x } / n, y: points.reduce(0) { $0 + $1.y } / n)
    }
}
