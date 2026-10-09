import Foundation

/// When FaceID asks the keychain by itself (`KeychainPrompt` in the app). After an update the keychain wants the user's
/// confirmation once before the new build may read the face and the password: the item's partition list holds the code
/// hash of the build that was allowed, and this build's hash is new. Asked at the wrong moment, the keychain's prompt
/// would come up on the lock screen, in front of nobody, or into the middle of a word typed in another app (the prompt's
/// password field takes the keys). So FaceID asks once per launch, and only when someone is at the unlocked Mac: the
/// keyboard, mouse or trackpad was touched after FaceID began to wait, no key went down for a moment, and FaceID is not
/// in the middle of something. After the screen has been locked, input counts again only a few seconds after the unlock,
/// so the prompt never comes with the unlock itself.
public struct KeychainPromptPlan: Equatable {
    public enum Step: Equatable {
        /// Not yet: the next tick looks again.
        case wait
        /// Ask the keychain now. Comes once per launch.
        case ask
        /// Nothing to wait for: not waiting, asked already, or confirmed meanwhile.
        case stop
    }

    /// What a tick looks at.
    public struct Facts: Equatable {
        public var now: Date
        /// The keychain still wants the confirmation.
        public var needsConfirmation: Bool
        /// The screen is locked, or this session is not the one at the console.
        public var locked: Bool
        /// FaceID is in the middle of something the prompt must not cut into (a face check, a setup step, the island
        /// showing something, a Touch ID prompt, an update going in).
        public var busy: Bool
        /// Since the last input of any kind: keyboard, mouse, trackpad.
        public var secondsSinceInput: TimeInterval
        public var secondsSinceKeyPress: TimeInterval

        public init(now: Date, needsConfirmation: Bool, locked: Bool, busy: Bool, secondsSinceInput: TimeInterval,
                    secondsSinceKeyPress: TimeInterval) {
            self.now = now
            self.needsConfirmation = needsConfirmation
            self.locked = locked
            self.busy = busy
            self.secondsSinceInput = secondsSinceInput
            self.secondsSinceKeyPress = secondsSinceKeyPress
        }
    }

    /// No key went down for this long: the user is not typing.
    public static let typingPause: TimeInterval = 1
    /// After an unlock, input counts only this much later.
    public static let afterUnlock: TimeInterval = 3

    /// Input after this moment counts as someone at the Mac; nil while the plan does not wait.
    public private(set) var since: Date?
    /// The keychain has been asked by itself in this launch.
    public private(set) var asked = false
    /// The screen was locked while waiting: the unlock sets `since` anew.
    private var lockSeen = false

    public init() {}

    /// Waits for someone at the Mac after `date` (a later moment than the one waited for already wins). Ignored once the
    /// keychain has been asked in this launch.
    public mutating func wait(since date: Date) {
        guard !asked else { return }
        if let since, since >= date { return }
        since = date
    }

    public mutating func step(_ facts: Facts) -> Step {
        guard !asked, let since else { return .stop }
        guard facts.needsConfirmation else {
            self.since = nil
            lockSeen = false
            return .stop
        }
        if facts.locked {
            lockSeen = true
            return .wait
        }
        if lockSeen {
            // The first look after the unlock: the keys of the unlock itself do not count.
            lockSeen = false
            wait(since: facts.now.addingTimeInterval(Self.afterUnlock))
            return .wait
        }
        let lastInput = facts.now.addingTimeInterval(-facts.secondsSinceInput)
        guard lastInput > since, facts.secondsSinceKeyPress >= Self.typingPause, !facts.busy else { return .wait }
        asked = true
        self.since = nil
        return .ask
    }
}
