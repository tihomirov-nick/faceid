import CoreGraphics
import CoreVideo
import Foundation

/// Records the owner's face: the person slowly turns their head in a circle while the camera collects embeddings
/// for every direction. As in Face ID setup on iPhone there are two passes around the circle; the second one adds
/// more shots of every direction (`beginNextPass`).
public final class EnrollmentSession: @unchecked Sendable {
    /// Directions around the ring of the setup screen.
    public static let segments = 24
    /// Segments that must be filled (the rest are usually extreme angles).
    public static let segmentsNeeded = 20
    /// Straight-ahead shots wanted in the first pass (the second one only goes around the circle).
    public static let frontalNeeded = 3

    public enum Hint: Sendable, Equatable {
        case noFace
        case multipleFaces
        case tooFar
        case tooDark
        case openEyes
        /// Look straight at the camera first: this sets the "straight" direction.
        case lookStraight
        /// Turn the head slowly in a circle.
        case turnHead
        /// The face does not match the one at the start (someone else in front of the camera).
        case otherPerson
        case done

        public var message: String {
            switch self {
            case .noFace: L("Поместите лицо в круг")
            case .multipleFaces: L("В кадре должен быть только один человек")
            case .tooFar: L("Подвиньтесь ближе")
            case .tooDark: L("Слишком темно, включите свет")
            case .openEyes: L("Откройте глаза")
            case .lookStraight: L("Посмотрите прямо в камеру")
            case .turnHead: L("Медленно двигайте головой по кругу")
            case .otherPerson: L("Это лицо не совпадает с лицом в начале записи")
            case .done: L("Готово")
            }
        }
    }

    public struct Progress: Sendable {
        /// Which pass around the circle this frame belongs to (1, 2): frames still on their way from before
        /// `beginNextPass` carry the old number and must be ignored.
        public var pass: Int
        /// Ring segments that have a template; index 0 points right, the angle grows clockwise (on screen,
        /// in the mirrored preview).
        public var covered: [Bool]
        public var frontal: Int
        public var hint: Hint
        public var face: DetectedFace?
        public var imageSize: CGSize
        /// Head direction relative to straight ahead, in degrees, as it looks in the mirrored preview
        /// (x to the right, y down).
        public var direction: CGPoint?
        public var fraction: Double {
            let segments = Double(covered.filter { $0 }.count) / Double(EnrollmentSession.segmentsNeeded)
            let frontal = Double(self.frontal) / Double(EnrollmentSession.frontalNeeded)
            return min(1, 0.85 * min(1, segments) + 0.15 * min(1, frontal))
        }
        public var done: Bool { hint == .done }

        public init(pass: Int = 1, covered: [Bool], frontal: Int, hint: Hint, face: DetectedFace?, imageSize: CGSize, direction: CGPoint?) {
            self.pass = pass
            self.covered = covered
            self.frontal = frontal
            self.hint = hint
            self.face = face
            self.imageSize = imageSize
            self.direction = direction
        }
    }

    private let appearance: Int
    private let allowExternalCamera: Bool
    private let lock = NSLock()
    private var camera: Camera?
    // Camera queue state
    private var neutralSamples: [(Double, Double)] = []
    private var neutral: (yaw: Double, pitch: Double)?
    private var templates: [Enrollment.Template] = []
    private var covered = Array(repeating: false, count: segments)
    private var frontalCount = 0
    private var lastFrontal: TimeInterval = 0
    private var pass = 1
    private var openness: [Double] = []
    private var reference: [Float]?

    public init(appearance: Int, allowExternalCamera: Bool) {
        self.appearance = appearance
        self.allowExternalCamera = allowExternalCamera
    }

    /// Starts the camera; `onProgress` is called for every frame on the camera queue.
    public func start(onProgress: @escaping @Sendable (Progress, CVPixelBuffer) -> Void) throws {
        let engine = try FaceEngine.shared()
        let camera = try Camera(allowExternal: allowExternalCamera)
        lock.withLock { self.camera = camera }
        camera.start { [weak self] buffer in
            guard let self else { return }
            let progress = autoreleasepool { self.process(buffer, engine: engine) }
            onProgress(progress, buffer)
        }
    }

    public func stop() {
        lock.withLock {
            camera?.stop()
            camera = nil
        }
    }

    /// Starts the next pass around the circle: the ring empties, the shots taken so far stay.
    public func beginNextPass() {
        lock.withLock {
            covered = Array(repeating: false, count: Self.segments)
            pass += 1
        }
    }

    /// The recorded face (call after `Progress.done`, or earlier to keep what was collected).
    public func result() -> (templates: [Enrollment.Template], openEyes: Double) {
        lock.withLock {
            let sorted = openness.sorted()
            return (templates, sorted.isEmpty ? 0.25 : sorted[sorted.count / 2])
        }
    }

    private func process(_ buffer: CVPixelBuffer, engine: FaceEngine) -> Progress {
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let faces = (try? engine.detector.detect(in: buffer)) ?? []
        func progress(_ hint: Hint, face: DetectedFace? = nil, direction: CGPoint? = nil) -> Progress {
            lock.withLock {
                // The pass is done as soon as the ring is (the first pass also wants a few straight-ahead shots,
                // and then says so instead of waiting silently).
                let ring = covered.filter { $0 }.count >= Self.segmentsNeeded
                let straight = pass > 1 || frontalCount >= Self.frontalNeeded
                let shown: Hint = ring ? (straight ? .done : .lookStraight) : hint
                return Progress(pass: pass, covered: covered, frontal: frontalCount, hint: shown, face: face,
                                imageSize: size, direction: direction)
            }
        }
        guard let face = faces.first else { return progress(.noFace) }
        if faces.count > 1, faces[1].bounds.width > face.bounds.width * 0.6 { return progress(.multipleFaces, face: face) }
        guard face.points.eyeDistance >= FaceScanner.minEyeDistance * 1.4 * size.width else { return progress(.tooFar, face: face) }
        let brightness = BGRAPixels.read(buffer) { $0.meanLuma(in: face.bounds) } ?? 255
        guard brightness >= FaceScanner.minBrightness + 10 else { return progress(.tooDark, face: face) }
        guard face.eyeOpenness >= 0.12 else { return progress(.openEyes, face: face) }
        guard let yawRadians = face.yaw, let pitchRadians = face.pitch else { return progress(.noFace, face: face) }
        let yaw = yawRadians * 180 / .pi, pitch = pitchRadians * 180 / .pi

        // "Straight ahead" is where this person looks at the camera from, not exactly 0°.
        guard let neutral else {
            if abs(yaw) < 15, abs(pitch) < 20 {
                neutralSamples.append((yaw, pitch))
                if neutralSamples.count >= 8 {
                    let yaws = neutralSamples.map(\.0).sorted(), pitches = neutralSamples.map(\.1).sorted()
                    self.neutral = (yaws[yaws.count / 2], pitches[pitches.count / 2])
                }
            }
            return progress(.lookStraight, face: face)
        }
        // Mirrored preview: turning to the right in the preview is negative yaw in the camera image.
        let direction = CGPoint(x: -(yaw - neutral.yaw), y: pitch - neutral.pitch)
        let magnitude = (direction.x * direction.x + direction.y * direction.y).squareRoot()

        guard let embedding = try? engine.embedding(of: buffer, points: face.points) else { return progress(.noFace, face: face) }
        if let reference, FaceMatcher.similarity(reference, embedding) < 0.4 {
            return progress(.otherPerson, face: face, direction: direction)
        }
        let template = Enrollment.Template(vector: embedding, yaw: yaw, pitch: pitch, appearance: appearance)
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            if magnitude < 7 {
                openness.append(face.eyeOpenness)
                if reference == nil { reference = embedding }
                if frontalCount < Self.frontalNeeded + 2, now - lastFrontal > 0.25 {
                    templates.append(template)
                    frontalCount += 1
                    lastFrontal = now
                }
            } else if magnitude >= 12, magnitude <= 45, reference != nil {
                var angle = atan2(direction.y, direction.x)
                if angle < 0 { angle += 2 * .pi }
                let segment = min(Self.segments - 1, Int(angle / (2 * .pi) * Double(Self.segments)))
                if !covered[segment] {
                    covered[segment] = true
                    templates.append(template)
                }
            }
        }
        return progress(.turnHead, face: face, direction: direction)
    }
}
