import CoreVideo
import FaceCore
import Foundation

/// Locks the Mac when the owner walks away. The camera turns on only after a while without keyboard and mouse
/// input (so it is not on while you work) and stays on until you are back or the screen locks; its green light
/// shows when it is watching. A few seconds before locking the island counts down: moving the mouse or looking
/// at the screen cancels it.
@MainActor
final class PresenceService {
    private weak var model: AppModel?
    private var timer: Timer?
    private var camera: Camera?
    private var lastSeen = Date()
    private var watchingSince: Date?

    private var countingDown = false

    /// Idle time before the camera starts checking.
    static let idleBeforeWatching: TimeInterval = 15
    /// The countdown in the island before locking.
    static let warning: TimeInterval = 5

    func start(model: AppModel) {
        self.model = model
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
    }

    private func tick() {
        guard let model, model.settings.autoLockEnabled, let enrollment = model.enrollment, model.cameraStatus == .authorized,
              !LockScreen.isLocked, !LockScreen.displayIsAsleep, model.activeScans == 0 else {
            stopWatching()
            return
        }
        let idle = LockScreen.secondsSinceInput
        if idle < 3 {
            stopWatching()
            return
        }
        if camera == nil, idle >= Self.idleBeforeWatching {
            startWatching(enrollment: enrollment, model: model)
        }
        guard camera != nil else { return }
        let away = Date().timeIntervalSince(lastSeen)
        let left = Int((model.settings.autoLockDelay - away).rounded(.up))
        if left <= 0 {
            Log.write(String(format: "auto-lock: no owner for %.0f s, locking", away))
            stopWatching()
            LockScreen.lock()
        } else if Double(left) <= Self.warning, !Island.shared.isShowing || countingDown {
            countingDown = true
            Island.shared.show(.countdown(left))
        } else {
            endCountdown()
        }
    }

    private func endCountdown() {
        guard countingDown else { return }
        countingDown = false
        if case .countdown = Island.shared.content { Island.shared.hide() }
    }

    private func startWatching(enrollment: Enrollment, model: AppModel) {
        guard let engine = try? FaceEngine.shared(), let camera = try? Camera(allowExternal: model.settings.allowExternalCamera) else { return }
        // Only "is it the owner": no attention or blink checks, and a slightly lower bar, since a wrong "yes" only
        // delays locking.
        var policy = model.settings.policy
        policy.threshold -= 0.05
        policy.requireAttention = false
        policy.requireBlink = false
        let scanner = FaceScanner(enrollment: enrollment, policy: policy, engine: engine)
        let threshold = policy.threshold
        var frame = 0
        self.camera = camera
        lastSeen = Date()
        watchingSince = Date()
        Log.write("auto-lock: watching")
        camera.start { buffer in
            frame += 1
            guard frame % 6 == 0 else { return } // about 5 checks a second is plenty
            let report = autoreleasepool { scanner.process(buffer) }
            if (report.similarity ?? -1) >= threshold {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.lastSeen = Date() }
                }
            }
        }
    }

    private func stopWatching() {
        endCountdown()
        guard let camera else { return }
        camera.stop()
        self.camera = nil
        if let watchingSince {
            Log.write(String(format: "auto-lock: stopped watching after %.0f s", Date().timeIntervalSince(watchingSince)))
        }
        watchingSince = nil
    }
}
