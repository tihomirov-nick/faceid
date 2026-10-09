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
    /// The island over the lock screen: the Face ID glyph scanning, then the green ring or the head shake.
    private let island = Island.lockScreen
    /// When the face was recognized: the approval finishes as soon as the screen unlocks.
    private var approvedAt: Date?

    /// Input in the first seconds after locking does not start a scan.
    static let grace: TimeInterval = 4
    static let scanTimeout: TimeInterval = 6
    static let maxAttempts = 5
    /// How long Face ID's approval (the green ring and the checkmark) stays before going back into the notch.
    static let approvalTime: TimeInterval = 1.6

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
        if let approvedAt, Date().timeIntervalSince(approvedAt) < 8 {
            playApproval(since: approvedAt)
        } else {
            island.hide()
        }
        approvedAt = nil
        // FaceID started (or was refused by the keychain) on the lock screen: now it may read the keychain. If the
        // keychain wants a confirmation, FaceID asks for it by itself the first time in this launch, on a touch a few
        // seconds after the unlock (the keys of the unlock do not count); after that the island's page asks.
        guard let model else { return }
        if model.secretsDeferred { model.loadSecrets() }
        if model.keychainNeedsConfirmation, !KeychainPrompt.shared.askedByItself {
            KeychainPrompt.shared.wait(since: Date().addingTimeInterval(KeychainPromptPlan.afterUnlock))
        } else if model.keychainNeedsConfirmation {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated {
                    guard model.keychainNeedsConfirmation, !LockScreen.isLocked, !Island.shared.isShowing else { return }
                    Setup.next()
                }
            }
        }
    }

    /// Unlocked by the face: Face ID's approval, as on iPhone, with the success sound. When the island above the lock
    /// screen already shows the green ring, it stays while the lock screen goes away and then slides back into the
    /// notch, one movement. When macOS kept the island under the lock screen, the ring comes out of the notch over the
    /// desktop now.
    func playApproval(since approvedAt: Date) {
        SoundEffects.play(.success)
        StatusItemController.shared.show(.success)
        if island.aboveLockScreen, case .scan(.success, _)? = island.content {
            island.hide(after: max(Self.approvalTime - Date().timeIntervalSince(approvedAt), 0.6))
            return
        }
        island.hide()
        guard model?.settings.lockScreenBadge == true else { return }
        Island.shared.show(.scan(.success, caption: nil))
        Island.shared.hide(after: Self.approvalTime)
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
        // A new version is going in and FaceID is about to restart: no scan that the restart would cut off.
        guard !UpdateCenter.shared.isInstalling else { return }
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
        StatusItemController.shared.show(.scanning)
        Log.write("lock screen: scanning (attempt \(attempts))" + (island.aboveLockScreen ? " · island above the lock screen" : ""))
        Task {
            let outcome = await session.run()
            model.scanEnded()
            guard self.session === session else { return }
            self.session = nil
            self.lastScanEnded = Date()
            // The menu bar is hidden on the lock screen: its checkmark comes with the approval after unlocking.
            StatusItemController.shared.show(outcome.isFailure ? .failure : .idle)
            switch outcome {
            case let .recognized(similarity, embedding):
                Log.write(String(format: "lock screen: recognized (similarity %.2f)", similarity))
                model.learn(embedding, similarity: similarity)
                Haptics.success()
                approvedAt = Date()
                if island.aboveLockScreen {
                    // Seen on the lock screen itself: the glyph turns into the green ring now and stays until the
                    // screen unlocks (`playApproval`).
                    showIsland(.success, model: model)
                } else {
                    island.hide()
                }
                await typePassword(model: model)
                // Still locked (the user was typing, the password did not work): the approval ends here.
                if LockScreen.isLocked { island.hide() }
            case let .failed(hint):
                Log.write("lock screen: not unlocked (\(hint))")
                Haptics.failure()
                SoundEffects.play(.failure)
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
        // Read silently: the keychain never asks on the lock screen. If it wants a confirmation, it is asked for after
        // the user unlocks.
        guard let password = PasswordStore.load() else {
            approvedAt = nil
            Log.write("lock screen: the keychain gave no password (none saved, or it needs a confirmation)")
            model.keychainRefused()
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

extension ScanSession.Outcome {
    /// The face was seen and not recognized (not a camera error or a cancelled scan).
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
