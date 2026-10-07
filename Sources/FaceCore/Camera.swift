import AVFoundation
import CoreVideo
import Foundation

/// Frames from the Mac's camera as 32BGRA buffers, delivered on a background queue.
public final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    public enum Failure: LocalizedError {
        case notAuthorized
        case noCamera
        case cannotStart

        public var errorDescription: String? {
            switch self {
            case .notAuthorized: L("Нет доступа к камере. Разрешите его в Системных настройках, раздел «Конфиденциальность и безопасность», пункт «Камера»")
            case .noCamera: L("Камера недоступна (крышка закрыта или камеру заняло другое приложение)")
            case .cannotStart: L("Не удалось включить камеру")
            }
        }
    }

    public static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
    public static var authorizationStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Cameras to scan with: the built-in one, and with `allowExternal` also USB and Continuity cameras.
    /// Virtual cameras (OBS and the like) also count as external, so they are off by default: a virtual camera
    /// can show a recorded video of the owner.
    public static func devices(allowExternal: Bool) -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if allowExternal { types += [.external, .continuityCamera] }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
            .filter { $0.isConnected && !$0.isSuspended }
            .sorted { ($0.deviceType == .builtInWideAngleCamera ? 0 : 1) < ($1.deviceType == .builtInWideAngleCamera ? 0 : 1) }
    }

    public let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.faceid.camera", qos: .userInteractive, autoreleaseFrequency: .workItem)
    private let lock = NSLock()
    private var handler: ((CVPixelBuffer) -> Void)?
    /// A camera is used once: after `stop` it never starts again, so a late `start` cannot leave it running.
    private var stopped = false

    public init(allowExternal: Bool) throws {
        guard Self.isAuthorized else { throw Failure.notAuthorized }
        guard let device = Self.devices(allowExternal: allowExternal).first else { throw Failure.noCamera }
        self.device = device
        super.init()
        // Center Stage crops and pans the picture; the face should stay where the camera really sees it.
        if AVCaptureDevice.centerStageControlMode != .user {
            AVCaptureDevice.centerStageControlMode = .app
            AVCaptureDevice.isCenterStageEnabled = false
        }
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            throw Failure.cannotStart
        }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw Failure.cannotStart
        }
        session.addOutput(output)
        session.commitConfiguration()
    }

    /// Starts delivering frames to `onFrame` (on the camera queue, one at a time; late frames are dropped).
    public func start(onFrame: @escaping (CVPixelBuffer) -> Void) {
        let start: Bool = lock.withLock {
            guard !stopped else { return false }
            handler = onFrame
            return true
        }
        guard start else { return }
        queue.async { [weak self, session] in
            // stop() may have come in between; it queues stopRunning after this block.
            guard let self, !self.lock.withLock({ self.stopped }) else { return }
            if !session.isRunning { session.startRunning() }
        }
    }

    public func stop() {
        lock.withLock {
            stopped = true
            handler = nil
        }
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    public var isRunning: Bool { session.isRunning }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = lock.withLock { self.handler }
        handler?(buffer)
    }

    deinit {
        if session.isRunning { session.stopRunning() }
    }
}
