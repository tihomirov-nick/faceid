import CoreGraphics
import XCTest
@testable import FaceCore

final class GeometryTests: XCTestCase {
    /// A known rotation + scale + shift is recovered exactly.
    func testSimilarityRecoversTransform() {
        let angle = 0.3, scale = 1.7
        let truth = Affine(a: scale * cos(angle), b: -scale * sin(angle), c: scale * sin(angle), d: scale * cos(angle), tx: 12, ty: -5)
        let source = FaceAlignment.template
        let target = source.map(truth.apply)
        let estimate = FaceAlignment.similarity(from: source, to: target)
        for (lhs, rhs) in [(estimate.a, truth.a), (estimate.b, truth.b), (estimate.c, truth.c), (estimate.d, truth.d), (estimate.tx, truth.tx), (estimate.ty, truth.ty)] {
            XCTAssertEqual(lhs, rhs, accuracy: 1e-9)
        }
        let back = estimate.inverted!
        for p in target {
            let q = estimate.apply(back.apply(p))
            XCTAssertEqual(q.x, p.x, accuracy: 1e-9)
            XCTAssertEqual(q.y, p.y, accuracy: 1e-9)
        }
    }

    /// Eye openness: wide eye outlines score higher than narrow ones.
    func testEyeOpenness() {
        func eye(height: Double) -> [CGPoint] {
            (0..<8).map { i in
                let t = Double(i) / 8 * 2 * .pi
                return CGPoint(x: -cos(t) * 10, y: -sin(t) * height)
            }
        }
        XCTAssertGreaterThan(DetectedFace.openness(eye(height: 4)), 0.3)
        XCTAssertLessThan(DetectedFace.openness(eye(height: 0.5)), 0.06)
    }
}
