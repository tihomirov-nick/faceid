import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

/// A face found in a frame. Coordinates are image pixels with the origin at the top left.
public struct DetectedFace: Sendable {
    /// Face box from Vision.
    public var bounds: CGRect
    /// Points the face is aligned by for recognition.
    public var points: FivePoints
    /// Eye outlines, the eye on the left of the image first (six points each).
    public var leftEye: [CGPoint]
    public var rightEye: [CGPoint]
    /// Head turn in radians as estimated by Vision.
    public var roll: Double?
    public var yaw: Double?
    public var pitch: Double?
    /// How sure Vision is about the landmarks (0...1).
    public var landmarksConfidence: Double
    /// Vision's face capture quality (0...1), when it was requested.
    public var captureQuality: Double?
    /// Every landmark region by name (only when requested, for calibration and debugging).
    public var regions: [String: [CGPoint]] = [:]

    /// Ratio of eye height to eye width, averaged over both eyes: about 0.25–0.35 for open eyes, much lower closed.
    public var eyeOpenness: Double {
        (Self.openness(leftEye) + Self.openness(rightEye)) / 2
    }

    static func openness(_ eye: [CGPoint]) -> Double {
        guard eye.count >= 6 else { return 0 }
        // The outline starts at one corner and goes around the eye; the far corner is halfway.
        let half = eye.count / 2
        let width = eye[0].distance(to: eye[half])
        guard width > 0 else { return 0 }
        var height = 0.0
        for i in 1..<half {
            height += eye[i].distance(to: eye[eye.count - i])
        }
        return height / Double(half - 1) / width
    }
}

/// Finds faces and their landmarks with the Vision framework.
public final class FaceDetector {
    public init() {}

    /// Faces in the buffer, largest first. `quality` adds Vision's capture quality (slower), `regions` keeps
    /// every landmark region.
    public func detect(in buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up,
                       quality: Bool = false, regions: Bool = false) throws -> [DetectedFace] {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
        // The rectangles request (revision 3) gives continuous yaw, pitch and roll; the landmarks request alone
        // rounds yaw to 45° and has no pitch.
        let rectangles = VNDetectFaceRectanglesRequest()
        rectangles.revision = VNDetectFaceRectanglesRequestRevision3
        try handler.perform([rectangles])
        guard let found = rectangles.results, !found.isEmpty else { return [] }
        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.revision = VNDetectFaceLandmarksRequestRevision3
        landmarks.constellation = .constellation76Points
        landmarks.inputFaceObservations = found
        try handler.perform([landmarks])
        let observations = landmarks.results ?? []
        guard !observations.isEmpty else { return [] }

        var qualities: [Double?] = Array(repeating: nil, count: observations.count)
        if quality {
            let request = VNDetectFaceCaptureQualityRequest()
            request.inputFaceObservations = observations
            try handler.perform([request])
            for (index, result) in (request.results ?? []).enumerated() where index < qualities.count {
                qualities[index] = result.faceCaptureQuality.map(Double.init)
            }
        }

        let width = Double(CVPixelBufferGetWidth(buffer)), height = Double(CVPixelBufferGetHeight(buffer))
        let size = orientation.rawValue >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        return observations.enumerated().compactMap { index, observation in
            Self.face(from: observation, imageSize: size, quality: qualities[index], keepRegions: regions)
        }
        .sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
    }

    static func face(from observation: VNFaceObservation, imageSize size: CGSize, quality: Double?, keepRegions: Bool) -> DetectedFace? {
        guard let landmarks = observation.landmarks else { return nil }
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            // Vision's origin is the bottom left.
            region?.pointsInImage(imageSize: size).map { CGPoint(x: $0.x, y: size.height - $0.y) } ?? []
        }
        let eyeA = points(landmarks.leftEye), eyeB = points(landmarks.rightEye)
        let pupilA = points(landmarks.leftPupil), pupilB = points(landmarks.rightPupil)
        let lips = points(landmarks.outerLips)
        let crest = points(landmarks.noseCrest), nose = points(landmarks.nose)
        guard eyeA.count >= 6, eyeB.count >= 6, lips.count >= 4, !crest.isEmpty || !nose.isEmpty else { return nil }

        var eyes = [(outline: eyeA, pupil: pupilA.first), (outline: eyeB, pupil: pupilB.first)]
        eyes.sort { CGPoint.mean($0.outline).x < CGPoint.mean($1.outline).x }
        let five = fivePoints(eyes: eyes.map { ($0.outline, $0.pupil) }, noseCrest: crest, nose: nose, outerLips: lips)

        let box = observation.boundingBox
        let bounds = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                            width: box.width * size.width, height: box.height * size.height)
        var face = DetectedFace(
            bounds: bounds, points: five, leftEye: eyes[0].outline, rightEye: eyes[1].outline,
            roll: observation.roll?.doubleValue, yaw: observation.yaw?.doubleValue, pitch: observation.pitch?.doubleValue,
            landmarksConfidence: Double(landmarks.confidence), captureQuality: quality
        )
        if keepRegions {
            let all: [(String, VNFaceLandmarkRegion2D?)] = [
                ("faceContour", landmarks.faceContour), ("leftEye", landmarks.leftEye), ("rightEye", landmarks.rightEye),
                ("leftEyebrow", landmarks.leftEyebrow), ("rightEyebrow", landmarks.rightEyebrow),
                ("nose", landmarks.nose), ("noseCrest", landmarks.noseCrest), ("medianLine", landmarks.medianLine),
                ("outerLips", landmarks.outerLips), ("innerLips", landmarks.innerLips),
                ("leftPupil", landmarks.leftPupil), ("rightPupil", landmarks.rightPupil),
            ]
            for (name, region) in all { face.regions[name] = points(region) }
        }
        return face
    }

    /// The five alignment points from Vision's landmarks: eye outline centers, the end of the nose crest and the lip
    /// outline points furthest along the eye line. On LFW this alignment gives SFace 99.55% accuracy, more than
    /// the 99.33% of OpenCV's own YuNet points; pupils or the nose outline center score the same within noise.
    static func fivePoints(eyes: [([CGPoint], CGPoint?)], noseCrest: [CGPoint], nose: [CGPoint], outerLips: [CGPoint]) -> FivePoints {
        let eyeCenters = eyes.map { outline, _ in CGPoint.mean(outline) }
        let axis = CGPoint(x: eyeCenters[1].x - eyeCenters[0].x, y: eyeCenters[1].y - eyeCenters[0].y)
        let along = { (p: CGPoint) in p.x * axis.x + p.y * axis.y }
        let mouthLeft = outerLips.min { along($0) < along($1) }!
        let mouthRight = outerLips.max { along($0) < along($1) }!
        let tip = noseCrest.last ?? CGPoint.mean(nose)
        return FivePoints(leftEye: eyeCenters[0], rightEye: eyeCenters[1], nose: tip, mouthLeft: mouthLeft, mouthRight: mouthRight)
    }
}
