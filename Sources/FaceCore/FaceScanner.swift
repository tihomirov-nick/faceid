import CoreGraphics
import CoreVideo
import Foundation

/// The neural networks, loaded once and shared: loading takes a few hundred milliseconds, and the lock screen
/// should not wait for it.
public final class FaceEngine: @unchecked Sendable {
    public let detector = FaceDetector()
    private let embedder: FaceEmbedder
    private let lock = NSLock()

    private static let sharedLock = NSLock()
    private static var instance: FaceEngine?

    public static func shared() throws -> FaceEngine {
        try sharedLock.withLock {
            if let instance { return instance }
            let engine = try FaceEngine()
            instance = engine
            return engine
        }
    }

    /// Loads the models in the background so that the first scan starts at once.
    public static func preload() {
        DispatchQueue.global(qos: .utility).async { _ = try? shared() }
    }

    private init() throws {
        embedder = try FaceEmbedder()
    }

    public func embedding(of buffer: CVPixelBuffer, points: FivePoints) throws -> [Float] {
        try lock.withLock { try embedder.embedding(of: buffer, points: points) }
    }
}

/// How strict recognition is.
public struct ScanPolicy: Codable, Sendable, Equatable {
    /// Similarity to the enrolled face needed (see `Enrollment.similarity`). On LFW photos SFace with this
    /// alignment mixes up two different people once in 100 000 comparisons at 0.47 and once in a million at 0.53;
    /// live frames of the owner usually score 0.6–0.85.
    public var threshold: Float
    /// Frames in a row that must match.
    public var requiredMatches: Int
    /// Eyes open and the face turned to the screen (a sleeping or turned-away owner does not unlock the Mac).
    public var requireAttention: Bool
    /// A blink must be seen during the scan: a photo cannot blink.
    public var requireBlink: Bool

    public init(threshold: Float = 0.55, requiredMatches: Int = 2, requireAttention: Bool = true, requireBlink: Bool = true) {
        self.threshold = threshold
        self.requiredMatches = requiredMatches
        self.requireAttention = requireAttention
        self.requireBlink = requireBlink
    }
}

/// What the person in front of the camera should do, or how the scan ended. The order is how far a scan got:
/// a timed-out scan reports the furthest state it reached.
public enum ScanHint: Int, Sendable, Comparable {
    case noFace
    case tooFar
    case tooDark
    case notRecognized
    case lookAtScreen
    case openEyes
    case blink
    /// Everything matches; waiting for one more frame to confirm.
    case checking
    case recognized

    public static func < (lhs: ScanHint, rhs: ScanHint) -> Bool { lhs.rawValue < rhs.rawValue }

    public var message: String {
        switch self {
        case .noFace: L("Лицо не видно")
        case .tooFar: L("Подвиньтесь ближе")
        case .tooDark: L("Слишком темно")
        case .notRecognized: L("Лицо не распознано")
        case .lookAtScreen: L("Посмотрите на экран")
        case .openEyes: L("Откройте глаза")
        case .blink: L("Моргните")
        case .checking: L("Проверка…")
        case .recognized: L("Лицо распознано")
        }
    }
}

/// One processed camera frame.
public struct FrameReport: Sendable {
    public var imageSize: CGSize
    public var face: DetectedFace?
    public var faceCount: Int
    public var similarity: Float?
    public var attentive: Bool
    public var blinked: Bool
    public var hint: ScanHint
    /// The face's embedding in this frame (for learning the owner's changing look after a sure match).
    public var embedding: [Float]?
    public var recognized: Bool { hint == .recognized }
}

/// Decides frame by frame whether the enrolled owner is in front of the camera.
/// Not thread-safe: feed it frames from one queue.
public final class FaceScanner {
    public let enrollment: Enrollment
    public let policy: ScanPolicy
    private let engine: FaceEngine
    private var matchStreak = 0
    private var blink = BlinkTracker()
    /// The furthest state reached, for the message after a failed scan.
    public private(set) var furthest: ScanHint = .noFace
    public private(set) var bestSimilarity: Float = -1

    public init(enrollment: Enrollment, policy: ScanPolicy, engine: FaceEngine) {
        self.enrollment = enrollment
        self.policy = policy
        self.engine = engine
    }

    /// Smallest face accepted: eye distance as a share of the frame width (about 1.3 m from a laptop camera).
    static let minEyeDistance = 0.025
    /// Mean brightness of the face below which the camera sees mostly noise.
    static let minBrightness = 30.0
    /// Head turn (degrees) still counted as looking at the screen.
    static let maxAttentionAngle = 30.0

    public func process(_ buffer: CVPixelBuffer, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> FrameReport {
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let faces = (try? engine.detector.detect(in: buffer)) ?? []
        guard let face = faces.first else {
            matchStreak = 0
            return report(size: size, face: nil, count: 0, similarity: nil, attentive: false, hint: .noFace)
        }
        if face.points.eyeDistance < Self.minEyeDistance * size.width {
            matchStreak = 0
            return report(size: size, face: face, count: faces.count, similarity: nil, attentive: false, hint: .tooFar)
        }
        let brightness = BGRAPixels.read(buffer) { $0.meanLuma(in: face.bounds) } ?? 255
        if brightness < Self.minBrightness {
            matchStreak = 0
            return report(size: size, face: face, count: faces.count, similarity: nil, attentive: false, hint: .tooDark)
        }

        let openness = face.eyeOpenness
        let reference = enrollment.openEyes > 0.05 ? enrollment.openEyes : 0.25
        let eyesOpen = openness >= max(0.1, reference * 0.55)
        let facing = abs(face.yaw.map { $0 * 180 / .pi } ?? 0) <= Self.maxAttentionAngle
            && abs(face.pitch.map { $0 * 180 / .pi } ?? 0) <= Self.maxAttentionAngle
        let attentive = eyesOpen && facing
        blink.add(openness: openness / reference, at: time)

        guard let embedding = try? engine.embedding(of: buffer, points: face.points) else {
            matchStreak = 0
            return report(size: size, face: face, count: faces.count, similarity: nil, attentive: attentive, hint: .noFace)
        }
        let similarity = enrollment.similarity(embedding)
        bestSimilarity = max(bestSimilarity, similarity)
        let matches = similarity >= policy.threshold
        matchStreak = matches ? matchStreak + 1 : 0

        let hint: ScanHint
        if !matches {
            hint = .notRecognized
        } else if policy.requireAttention && !facing {
            hint = .lookAtScreen
        } else if policy.requireAttention && !eyesOpen {
            hint = .openEyes
        } else if policy.requireBlink && !blink.seen {
            hint = .blink
        } else if matchStreak < policy.requiredMatches {
            hint = .checking
        } else {
            hint = .recognized
        }
        return report(size: size, face: face, count: faces.count, similarity: similarity, attentive: attentive,
                      hint: hint, embedding: embedding)
    }

    private func report(size: CGSize, face: DetectedFace?, count: Int, similarity: Float?, attentive: Bool,
                        hint: ScanHint, embedding: [Float]? = nil) -> FrameReport {
        furthest = max(furthest, hint)
        return FrameReport(imageSize: size, face: face, faceCount: count, similarity: similarity,
                           attentive: attentive, blinked: blink.seen, hint: hint, embedding: embedding)
    }
}

/// Spots a blink in the eye openness of consecutive frames: the eyes close well below their open level and open
/// again within a moment. Openness is given relative to the person's usual open eyes.
struct BlinkTracker {
    private(set) var seen = false
    private var closedSince: TimeInterval?
    private var openBefore = false

    mutating func add(openness: Double, at time: TimeInterval) {
        if openness < 0.5 {
            if closedSince == nil, openBefore { closedSince = time }
        } else if openness > 0.75 {
            if let start = closedSince, time - start <= 0.8 { seen = true }
            closedSince = nil
            openBefore = true
        }
        if let start = closedSince, time - start > 0.8 {
            // Eyes closed for long: not a blink (and no longer "open before").
            closedSince = nil
            openBefore = false
        }
    }
}

/// Runs the camera and a `FaceScanner` until the owner is recognized, the time runs out or it is cancelled.
public final class ScanSession: @unchecked Sendable {
    public enum Outcome: Sendable, Equatable {
        case recognized(similarity: Float, embedding: [Float])
        case failed(ScanHint)
        case cameraError(String)
        case cancelled
    }

    private let enrollment: Enrollment
    private let policy: ScanPolicy
    private let allowExternalCamera: Bool
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var camera: Camera?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var finished = false
    private var furthest: ScanHint = .noFace

    public init(enrollment: Enrollment, policy: ScanPolicy, allowExternalCamera: Bool, timeout: TimeInterval) {
        self.enrollment = enrollment
        self.policy = policy
        self.allowExternalCamera = allowExternalCamera
        self.timeout = timeout
    }

    /// Scans; `onFrame` gets every processed frame on the camera queue (for previews).
    public func run(onFrame: (@Sendable (FrameReport, CVPixelBuffer) -> Void)? = nil) async -> Outcome {
        let engine: FaceEngine
        do {
            engine = try FaceEngine.shared()
        } catch {
            return .cameraError(error.localizedDescription)
        }
        let scanner = FaceScanner(enrollment: enrollment, policy: policy, engine: engine)
        return await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            if lock.withLock({ finished }) {
                finish(.cancelled)
                return
            }
            let camera: Camera
            do {
                camera = try Camera(allowExternal: allowExternalCamera)
            } catch {
                finish(.cameraError(error.localizedDescription))
                return
            }
            // cancel() may have run meanwhile; a camera stopped once never starts again (Camera.stop).
            lock.withLock { self.camera = camera }
            if lock.withLock({ finished }) { camera.stop() }
            camera.start { [weak self] buffer in
                guard let self else { return }
                let report = autoreleasepool { scanner.process(buffer) }
                self.lock.withLock { self.furthest = scanner.furthest }
                onFrame?(report, buffer)
                if report.recognized {
                    self.finish(.recognized(similarity: report.similarity ?? 0, embedding: report.embedding ?? []))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.finish(.failed(self.lock.withLock { self.furthest }))
            }
        }
    }

    public func cancel() {
        finish(.cancelled)
    }

    private func finish(_ outcome: Outcome) {
        let (continuation, camera): (CheckedContinuation<Outcome, Never>?, Camera?) = lock.withLock {
            guard !finished || continuation != nil else { return (nil, nil) }
            finished = true
            defer { self.continuation = nil; self.camera = nil }
            return (self.continuation, self.camera)
        }
        camera?.stop()
        continuation?.resume(returning: outcome)
    }
}
