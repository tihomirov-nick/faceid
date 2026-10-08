import AVFoundation
import FaceCore
import SwiftUI

/// Face setup in the island under the notch, like Face ID setup on iPhone: the face in a circle right below
/// the camera, ticks around it turn green as the head turns, two passes around the circle.
@MainActor
final class EnrollModel: ObservableObject {
    enum Phase: Equatable {
        /// Waiting for Touch ID or the password, and for the camera.
        case starting
        case scanning(pass: Int)
        case passDone
        case finished
        case failed(String)
    }

    /// What the recording is for.
    enum Purpose: Equatable {
        /// The first face, during setup.
        case first
        /// One more face (another look, another person).
        case add
        /// A face recorded again.
        case redo(Int)
    }

    @Published var phase: Phase = .starting
    @Published var progress: EnrollmentSession.Progress?
    let purpose: Purpose
    let feed = PreviewFeed()
    private var session: EnrollmentSession?
    private var scanning = false
    private var recorded: (templates: [Enrollment.Template], openEyes: Double)?
    /// Closed (Cancel, or the island showed something else): a confirmation that arrives later starts nothing.
    private var closed = false

    init(purpose: Purpose) {
        self.purpose = purpose
    }

    /// Opens the recording in the island and starts it.
    static func present(_ purpose: Purpose) {
        let model = EnrollModel(purpose: purpose)
        Island.shared.show(.enroll(model)) { model.cancel() }
        model.begin()
    }

    func close() {
        cancel()
        Island.shared.hide()
    }

    private func cancel() {
        closed = true
        stop()
    }

    /// As on iPhone, the face can only be set up after the passcode (here Touch ID or the login password):
    /// otherwise anyone at an unlocked Mac could add their face.
    func begin() {
        phase = .starting
        Task {
            guard await AppModel.shared.confirmOwner() else {
                if !closed { close() }
                return
            }
            if Camera.authorizationStatus == .notDetermined {
                _ = await Camera.requestAccess()
                AppModel.shared.refresh()
            }
            startCamera()
        }
    }

    private func startCamera() {
        let model = AppModel.shared
        guard !closed else { return }
        guard Camera.isAuthorized else {
            phase = .failed(Camera.Failure.notAuthorized.localizedDescription)
            return
        }
        let session = EnrollmentSession(appearance: 0, allowExternalCamera: model.settings.allowExternalCamera)
        do {
            try session.start { [weak self, feed] progress, buffer in
                feed.push(buffer)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.update(progress) }
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        self.session = session
        progress = nil
        phase = .scanning(pass: 1)
        if !scanning {
            scanning = true
            model.scanStarted()
        }
    }

    private func update(_ progress: EnrollmentSession.Progress) {
        guard case let .scanning(pass) = phase, progress.pass == pass else { return }
        self.progress = progress
        guard progress.done else { return }
        Haptics.success()
        if pass == 1 {
            phase = .passDone
        } else {
            // The second circle is complete: keep the face right away and show the checkmark.
            recorded = session?.result()
            stop()
            save()
        }
    }

    /// "Continue" after the first pass.
    func nextPass() {
        session?.beginNextPass()
        progress = nil
        phase = .scanning(pass: 2)
    }

    func stop() {
        session?.stop()
        session = nil
        if scanning {
            scanning = false
            AppModel.shared.scanEnded()
        }
    }

    /// Keeps the recorded face, shows the checkmark and goes on with the setup by itself.
    private func save() {
        guard let (templates, openEyes) = recorded else { return }
        let model = AppModel.shared
        switch (purpose, model.enrollment) {
        case let (.redo(face), existing?):
            model.save(existing.replacing(face: face, with: templates))
        case let (.add, existing?):
            model.save(existing.adding(face: L("Лицо %@", "\(existing.faces.count + 1)"), templates: templates))
        default:
            model.save(Enrollment(face: Enrollment.firstName, templates: templates, openEyes: openEyes))
        }
        phase = .finished
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.done() }
        }
    }

    /// After the checkmark ("Done", or by itself): the next setup step, or back to the controls.
    func done() {
        guard phase == .finished, !closed else { return }
        closed = true
        if purpose == .first { Setup.next() } else { Island.shared.show(.faces) }
    }

    #if DEBUG
    /// Debug hooks: the setup island with made-up progress ("1:10" = first pass, 10 segments; "passDone"; "done").
    static func presentDemo(_ value: String) {
        let model = EnrollModel(purpose: .first)
        let parts = value.split(separator: ":").map(String.init)
        switch parts.first {
        case "passDone": model.phase = .passDone
        case "done": model.phase = .finished
        case "starting", nil: model.phase = .starting
        default:
            let pass = Int(parts[0]) ?? 1, count = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            model.phase = .scanning(pass: pass)
            var covered = Array(repeating: false, count: EnrollmentSession.segments)
            for index in 0..<min(count, covered.count) { covered[(index * 7) % covered.count] = true }
            model.progress = EnrollmentSession.Progress(pass: pass, covered: covered, frontal: 4, hint: .turnHead, face: nil,
                                                        imageSize: .zero, direction: CGPoint(x: 20, y: -10))
        }
        Island.shared.show(.enroll(model))
    }
    #endif
}

struct EnrollView: View {
    @ObservedObject var enroll: EnrollModel

    var body: some View {
        VStack(spacing: 12) {
            switch enroll.phase {
            case .starting, .scanning, .passDone: scanner
            case .finished: finished
            case let .failed(message): failure(message)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .foregroundStyle(.white)
    }

    private var scanner: some View {
        VStack(spacing: 10) {
            Text(headline)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .frame(height: 34)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: headline)
            ZStack {
                if enroll.phase == .starting {
                    FaceIDGlyph(phase: .scanning, size: 66)
                } else {
                    CameraPreview(feed: enroll.feed)
                        .frame(width: 176, height: 176)
                        .clipShape(Circle())
                        .overlay(Circle().fill(.black.opacity(enroll.phase == .passDone ? 0.45 : 0)))
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
                TickRing(covered: enroll.phase == .passDone ? nil : enroll.progress?.covered,
                         direction: enroll.phase == .passDone ? nil : enroll.progress?.direction)
                    .frame(width: 246, height: 246)
                    .opacity(enroll.phase == .starting ? 0.4 : 1)
            }
            .frame(height: 246)
            .animation(.easeInOut(duration: 0.3), value: enroll.phase)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button(L("Отмена")) { enroll.close() }
                    .appButton(.secondary)
                    .keyboardShortcut(.cancelAction)
                if enroll.phase == .passDone {
                    Button(L("Продолжить")) { enroll.nextPass() }
                        .appButton(.primary)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// Only what to do right now, as on iPhone.
    private var headline: String {
        switch enroll.phase {
        case .starting:
            return ""
        case .passDone:
            return L("Первое сканирование завершено")
        case let .scanning(pass):
            let hint = enroll.progress?.hint ?? .noFace
            if hint == .turnHead {
                return pass == 1 ? L("Медленно двигайте головой, чтобы завершить круг")
                                 : L("Медленно двигайте головой, чтобы завершить круг во второй раз")
            }
            return hint.message
        default:
            return ""
        }
    }

    private var finished: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            FaceIDGlyph(phase: .success, size: 100)
            Spacer(minLength: 0)
            Button(L("Готово")) { enroll.done() }
                .appButton(.primary)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            FaceIDGlyph(phase: .failure, size: 80)
            Text(message)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button(L("Закрыть")) { enroll.close() }
                    .appButton(.secondary)
                    .keyboardShortcut(.cancelAction)
                if Camera.authorizationStatus == .denied {
                    Button(L("Открыть настройки")) { AppModel.shared.openPrivacySettings("Privacy_Camera") }
                        .appButton(.primary)
                } else {
                    Button(L("Еще раз")) { enroll.begin() }
                        .appButton(.primary)
                }
            }
        }
    }
}

/// The ring of ticks around the face: green where a head turn is recorded (longer, with a spring), the current
/// direction lit; all green when a pass is complete (`covered` nil).
struct TickRing: View {
    let covered: [Bool]?
    let direction: CGPoint?
    static let ticks = 72

    var body: some View {
        GeometryReader { geometry in
            let radius = min(geometry.size.width, geometry.size.height) / 2 - 20
            let segments = EnrollmentSession.segments
            let pointing = pointedSegment(segments)
            ZStack {
                ForEach(0..<Self.ticks, id: \.self) { index in
                    let segment = index * segments / Self.ticks
                    let done = covered.map { $0[segment] } ?? true
                    let lit = !done && segment == pointing
                    Capsule()
                        .fill(done ? Color.green : (lit ? Color.white : Color.white.opacity(0.28)))
                        .frame(width: 3, height: done ? 16 : (lit ? 12 : 9))
                        .offset(y: -radius - (done ? 8 : (lit ? 6 : 4.5)))
                        .rotationEffect(.degrees((Double(index) + 0.5) / Double(Self.ticks) * 360 + 90))
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: done)
                        .animation(.easeOut(duration: 0.15), value: lit)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityLabel(L("Прогресс записи лица"))
    }

    private func pointedSegment(_ segments: Int) -> Int? {
        guard let d = direction else { return nil }
        guard (d.x * d.x + d.y * d.y).squareRoot() > 8 else { return nil }
        var angle = atan2(d.y, d.x)
        if angle < 0 { angle += 2 * .pi }
        return Int(angle / (2 * .pi) * Double(segments)) % segments
    }
}
