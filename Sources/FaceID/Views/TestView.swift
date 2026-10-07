import AVFoundation
import FaceCore
import SwiftUI

/// Live check of recognition in the island: what FaceID sees and how sure it is, plus a scan exactly like
/// the lock screen's.
@MainActor
final class TestModel: ObservableObject {
    @Published var report: FrameReport?
    @Published var error: String?
    @Published var scanResult: ScanSession.Outcome?
    @Published var scanning = false
    let feed = PreviewFeed()
    private var camera: Camera?
    private var session: ScanSession?
    private var counted = false

    static func present() {
        guard !Island.shared.showsSudoPrompt else { return }
        let model = TestModel()
        Island.shared.show(.test(model)) { model.stop() }
        model.start()
    }

    func close() {
        stop()
        Island.shared.hide()
    }

    func start() {
        let model = AppModel.shared
        guard camera == nil, session == nil, let enrollment = model.enrollment else { return }
        guard Camera.isAuthorized else {
            error = Camera.Failure.notAuthorized.localizedDescription
            return
        }
        do {
            let engine = try FaceEngine.shared()
            let camera = try Camera(allowExternal: model.settings.allowExternalCamera)
            let scanner = FaceScanner(enrollment: enrollment, policy: model.settings.policy, engine: engine)
            camera.start { [weak self, feed] buffer in
                feed.push(buffer)
                let report = autoreleasepool { scanner.process(buffer) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.report = report }
                }
            }
            self.camera = camera
            error = nil
            count(true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        camera?.stop()
        camera = nil
        session?.cancel()
        count(false)
    }

    private func count(_ on: Bool) {
        guard on != counted else { return }
        counted = on
        if on { AppModel.shared.scanStarted() } else { AppModel.shared.scanEnded() }
    }

    /// The same scan as on the lock screen (same rules and time limit), without typing the password.
    func runScan() {
        let model = AppModel.shared
        camera?.stop()
        camera = nil
        guard let session = model.makeScan(timeout: UnlockService.scanTimeout) else { return }
        self.session = session
        scanning = true
        scanResult = nil
        count(true)
        Task {
            let outcome = await session.run { [feed] report, buffer in
                feed.push(buffer)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.report = report }
                }
            }
            self.session = nil
            self.scanning = false
            guard outcome != .cancelled else { return }
            self.scanResult = outcome
            if case .recognized = outcome { Haptics.success() } else { Haptics.failure() }
            switch outcome {
            case let .recognized(similarity, _): Log.write(String(format: "test scan: recognized (similarity %.2f)", similarity))
            case let .failed(hint): Log.write("test scan: not recognized (\(hint))")
            case let .cameraError(message): Log.write("test scan: camera error: \(message)")
            case .cancelled: break
            }
            self.start()
        }
    }
}

/// What the camera sees with the face box, how close it is to the enrolled face, and one button that scans exactly
/// like the lock screen.
struct TestView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var test: TestModel

    var body: some View {
        VStack(spacing: 10) {
            preview
            HStack(spacing: 8) {
                Button(L("Готово")) { test.close() }
                    .appButton(.secondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(test.scanning ? L("Сканирую…") : L("Проверить")) { test.runScan() }
                    .appButton(.primary)
                    .disabled(test.scanning || !model.isEnrolled)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .foregroundStyle(.white)
    }

    private var preview: some View {
        ZStack {
            CameraPreview(feed: test.feed)
            if let report = test.report, let face = report.face {
                GeometryReader { geometry in
                    let mapping = PreviewMapping(imageSize: report.imageSize, viewSize: geometry.size)
                    let box = mapping.rect(face.bounds)
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(color(for: report), lineWidth: 2.5)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                        .animation(.easeOut(duration: 0.1), value: box)
                }
            }
            if let error = test.error {
                CameraUnavailableView(message: error,
                                      action: model.cameraStatus == .authorized ? nil : (L("Разрешить камеру"), { model.requestCamera() }))
            }
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    FaceIDGlyph(phase: glyphPhase, size: 26)
                    if let similarity = test.report?.similarity, !test.scanning, test.scanResult == nil {
                        Text("\(Int((max(0, similarity) * 100).rounded()))%")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(12)
                .opacity(test.error == nil ? 1 : 0)
            }
        }
        .frame(height: 196)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var glyphPhase: GlyphPhase {
        if test.scanning { return .scanning }
        switch test.scanResult {
        case .recognized: return .success
        case .failed, .cameraError: return .failure
        default: return .idle
        }
    }

    private func color(for report: FrameReport) -> Color {
        switch report.hint {
        case .recognized, .checking: .green
        case .notRecognized, .spoof: .red
        default: .yellow
        }
    }
}
