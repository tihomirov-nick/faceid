import AppKit
import FaceCore

/// The keychain's confirmation, asked once after every update (see `KeychainPromptPlan` for why and when). FaceID asks
/// by itself as soon as someone is at the unlocked Mac: the island says that macOS is about to ask and which button to
/// press, and the keychain's own prompt comes up, so FaceID unlocks by face again before the Mac is next locked. It never
/// weakens the item's access list: "Always Allow" in the keychain's prompt is what lets the new build in. If the user
/// denies it or presses "Allow" (this once only), the island's keychain page takes over with "Continue", as it does
/// whenever the controls are opened before the confirmation.
@MainActor
final class KeychainPrompt: ObservableObject {
    static let shared = KeychainPrompt()

    /// The keychain's prompt is up, asked by FaceID or from the page.
    @Published private(set) var asking = false
    /// The last answer was "Allow": it worked this once, and the keychain would ask at the next launch again.
    @Published private(set) var onlyOnce = false
    /// Answers that did not let FaceID in, for the page's shake.
    @Published private(set) var refusals = 0

    private var plan = KeychainPromptPlan()
    private var timer: Timer?

    private init() {}

    /// FaceID has asked by itself in this launch already: from now on the page asks.
    var askedByItself: Bool { plan.asked }

    /// The keychain wants the confirmation: asked by itself on the first touch of the keyboard, mouse or trackpad after
    /// `date` while the screen is unlocked.
    func wait(since date: Date = Date()) {
        plan.wait(since: date)
        guard plan.since != nil, timer == nil else { return }
        Log.write("keychain: needs a confirmation, FaceID asks as soon as someone is at the Mac")
        // Common modes: a menu held open must not hold the prompt back for good.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let model = AppModel.shared
        let facts = KeychainPromptPlan.Facts(
            now: Date(), needsConfirmation: model.keychainNeedsConfirmation,
            locked: LockScreen.isLocked || !LockScreen.isOnConsole, busy: busy,
            secondsSinceInput: LockScreen.secondsSinceInput, secondsSinceKeyPress: LockScreen.secondsSinceKeyPress)
        switch plan.step(facts) {
        case .wait:
            return
        case .stop:
            stopWaiting()
        case .ask:
            stopWaiting()
            askByItself()
        }
    }

    /// Something the prompt must not cut into: a face being checked or recorded, the island showing anything (a setup
    /// step, the controls, the countdown, the approval), a Touch ID prompt, an update going in.
    private var busy: Bool {
        asking || AppModel.shared.activeScans > 0 || Island.shared.isShowing || Island.shared.keepOpen
            || Island.lockScreen.isShowing || UpdateCenter.shared.isInstalling
    }

    private func stopWaiting() {
        timer?.invalidate()
        timer = nil
    }

    private func askByItself() {
        Log.write("keychain: someone is at the Mac, asking for the confirmation")
        Island.shared.show(.keychainHint)
        Task { await confirm(byItself: true) }
    }

    /// The keychain's own prompt, from the page's "Continue" or by itself.
    func confirm(byItself: Bool = false) async {
        guard !asking else { return }
        asking = true
        // The keychain's prompt is another window: clicks in it must not close the island.
        Island.shared.keepOpen = true
        let result = await AppModel.shared.confirmKeychain()
        Island.shared.keepOpen = false
        asking = false
        onlyOnce = result == .onlyOnce
        let model = AppModel.shared
        switch result {
        case .granted where byItself && model.canUnlock:
            // Nothing else is missing: FaceID unlocks by face again, and only says so.
            Haptics.success()
            SoundEffects.play(.success)
            Island.shared.show(.ready)
            Island.shared.hide(after: 1.6)
        case .granted:
            Setup.next()
        case .onlyOnce, .denied:
            refusals += 1
            if byItself {
                // The page explains what is left and asks again with "Continue" ("Later" leaves it for now).
                if !LockScreen.isLocked { Island.shared.show(.keychain) } else { Island.shared.hide() }
            } else {
                Haptics.failure()
                SoundEffects.play(.failure)
            }
        }
    }
}
