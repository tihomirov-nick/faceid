import AppKit
import FaceCore
import Foundation
import SwiftUI

/// Unlocks the lock screen when the owner looks at the Mac, then plays Face ID's approval in the notch.
///
/// A scan starts only on a sign that someone wants in, as with Apple Watch unlocking: the display wakes up
/// (a key press, the lid opened) or the keyboard, mouse or trackpad is touched while the lock screen is shown.
/// Touches in the first seconds after locking are ignored, so locking the Mac while sitting in front of it keeps
/// it locked. When the face is recognized, FaceID types the login password into the lock screen.
@MainActor
final class UnlockService {
    private weak var model: AppModel?
    private var lockedAt: Date?
    private var displayWokeAt: Date?
    private var lastScanEnded = Date.distantPast
    private var session: ScanSession?
    private var attempts = 0
    /// The password was typed for this lock: never type it twice (a wrong password counts as a failed login).
    private var typed = false
    private var timer: Timer?
    /// The island over the lock screen: the Face ID glyph while scanning (where macOS lets it show there).
    private let island = Island.lockScreen
    /// The face was recognized and the password typed: the approval plays as soon as the screen unlocks.
    private var approvedAt: Date?

    /// Input in the first seconds after locking does not start a scan.
    static let grace: TimeInterval = 4
    static let scanTimeout: TimeInterval = 6
    static let maxAttempts = 5

    func start(model: AppModel) {
        self.model = model
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.screenLocked() }
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.screenUnlocked() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.displayWoke() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.displayWoke() }
        }
        if LockScreen.isLocked { screenLocked() }
    }

    private func screenLocked() {
        guard lockedAt == nil else { return }
        lockedAt = Date()
        displayWokeAt = nil
        attempts = 0
        typed = false
        Log.write("screen locked")
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
    }

    private func screenUnlocked() {
        timer?.invalidate()
        timer = nil
        session?.cancel()
        session = nil
        if lockedAt != nil { Log.write("screen unlocked") }
        lockedAt = nil
        island.hide()
        // Unlocked by the face: the green ring and the checkmark come out of the notch over the desktop, like Face
        // ID's approval on iPhone. (macOS does not show other apps' windows on the lock screen itself.)
        if let approvedAt, Date().timeIntervalSince(approvedAt) < 8, model?.settings.lockScreenBadge == true {
            Island.shared.show(.scan(.success, caption: nil))
            Island.shared.hide(after: 1.6)
        }
        approvedAt = nil
    }

    private func displayWoke() {
        guard lockedAt != nil else { return }
        displayWokeAt = Date()
        tick()
    }

    private func tick() {
        // A missed "unlocked" notification must not leave the service thinking the screen is still locked.
        if lockedAt != nil, !LockScreen.isLocked {
            screenUnlocked()
            return
        }
        guard let model, let lockedAt, model.settings.unlockEnabled, model.canUnlock else { return }
        guard LockScreen.isLocked, !LockScreen.displayIsAsleep else { return }
        guard session == nil, !typed, attempts < Self.maxAttempts, Date().timeIntervalSince(lastScanEnded) > 1.5 else { return }
        let lastInput = Date(timeIntervalSinceNow: -LockScreen.secondsSinceInput)
        let woke = displayWokeAt.map { $0 > lastScanEnded } ?? false
        let touched = lastInput > lockedAt.addingTimeInterval(Self.grace) && lastInput > lastScanEnded
        guard woke || touched else { return }
        displayWokeAt = nil
        scan(model: model)
    }

    private func scan(model: AppModel) {
        guard let session = model.makeScan(timeout: Self.scanTimeout) else { return }
        attempts += 1
        self.session = session
        model.scanStarted()
        showIsland(.scanning, model: model)
        Log.write("lock screen: scanning (attempt \(attempts))")
        Task {
            let outcome = await session.run()
            model.scanEnded()
            guard self.session === session else { return }
            self.session = nil
            self.lastScanEnded = Date()
            switch outcome {
            case let .recognized(similarity, embedding):
                Log.write(String(format: "lock screen: recognized (similarity %.2f)", similarity))
                model.learn(embedding, similarity: similarity)
                Haptics.success()
                island.hide()
                approvedAt = Date()
                await typePassword(model: model)
            case let .failed(hint):
                Log.write("lock screen: not unlocked (\(hint))")
                Haptics.failure()
                showIsland(.failure, model: model)
                island.hide(after: 1.1)
            case let .cameraError(message):
                Log.write("lock screen: camera error: \(message)")
                island.hide()
            case .cancelled:
                island.hide()
            }
        }
    }

    private func showIsland(_ phase: GlyphPhase, model: AppModel) {
        guard model.settings.lockScreenBadge else { return }
        island.show(.scan(phase, caption: nil))
    }

    private func typePassword(model: AppModel) async {
        guard let password = PasswordStore.load() else {
            approvedAt = nil
            Log.write("lock screen: no saved password")
            return
        }
        // Let the person finish a key press (the key that woke the screen); someone typing the password
        // themselves is left alone.
        for _ in 0..<25 where LockScreen.secondsSinceKeyPress < 0.5 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard LockScreen.secondsSinceKeyPress >= 0.5 else {
            Log.write("lock screen: the user is typing, not entering the password")
            approvedAt = nil
            return
        }
        if LockScreen.screenSaverIsRunning {
            postKey(53) // Escape: closes the screen saver and shows the password field
            try? await Task.sleep(for: .milliseconds(500))
        }
        Log.write("lock screen: \(LockScreen.focusDiagnostics)")
        var result = await Task.detached { LockScreen.type(password: password) }.value
        if result == .fieldNotFocused {
            // The password field may appear a moment after the display wakes.
            LockScreen.wakeDisplay()
            try? await Task.sleep(for: .milliseconds(700))
            result = await Task.detached { LockScreen.type(password: password) }.value
        }
        guard result == .typed else {
            // Never typed blind: without proof that the lock screen has the keyboard the keys could reach another app.
            Log.write("lock screen: password not typed (\(result)) · \(LockScreen.focusDiagnostics)")
            approvedAt = nil
            return
        }
        typed = true
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(100))
            if !LockScreen.isLocked { return }
        }
        Log.write("lock screen: still locked after typing the password")
        approvedAt = nil
        model.passwordProblem = true
    }

    private func postKey(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
