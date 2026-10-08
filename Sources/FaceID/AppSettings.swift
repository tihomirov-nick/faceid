import FaceCore
import Foundation

/// How sure FaceID must be that it sees the owner.
enum Strictness: Int, CaseIterable, Identifiable {
    case relaxed
    case standard
    case strict

    var id: Int { rawValue }

    /// Similarity thresholds, measured on LFW (scripts/eval_lfw.py): a stranger passes about once in 100 000
    /// comparisons at 0.48, once in a million at 0.55, less often at 0.62.
    var threshold: Float {
        switch self {
        case .relaxed: 0.48
        case .standard: 0.55
        case .strict: 0.62
        }
    }

    var title: String {
        switch self {
        case .relaxed: L("Мягкая")
        case .standard: L("Обычная")
        case .strict: L("Строгая")
        }
    }
}

/// User settings in UserDefaults (com.faceid.app). Nothing secret: the face and the password are in the Keychain.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let unlock = "unlockEnabled"
        static let autoLock = "autoLockEnabled"
        static let autoLockDelay = "autoLockDelay"
        static let strictness = "strictness"
        static let attention = "requireAttention"
        static let blink = "requireBlink"
        static let externalCamera = "allowExternalCamera"
        static let badge = "lockScreenBadge"
        static let sounds = "soundEffects"
    }

    @Published var unlockEnabled: Bool { didSet { defaults.set(unlockEnabled, forKey: Key.unlock) } }
    @Published var autoLockEnabled: Bool { didSet { defaults.set(autoLockEnabled, forKey: Key.autoLock) } }
    /// Seconds without the owner in front of the camera before the screen locks.
    @Published var autoLockDelay: Double { didSet { defaults.set(autoLockDelay, forKey: Key.autoLockDelay) } }
    @Published var strictness: Strictness { didSet { defaults.set(strictness.rawValue, forKey: Key.strictness) } }
    @Published var requireAttention: Bool { didSet { defaults.set(requireAttention, forKey: Key.attention) } }
    /// The only check against a photo held up to the camera, so it is on by default.
    @Published var requireBlink: Bool { didSet { defaults.set(requireBlink, forKey: Key.blink) } }
    @Published var allowExternalCamera: Bool { didSet { defaults.set(allowExternalCamera, forKey: Key.externalCamera) } }
    /// Show the scan in the island above the lock screen and Face ID's approval in the notch after unlocking: one
    /// animation, so one switch ("Unlock Animation").
    @Published var lockScreenBadge: Bool { didSet { defaults.set(lockScreenBadge, forKey: Key.badge) } }
    /// Short system sounds for the moments that matter (`SoundEffects`).
    @Published var soundEffects: Bool { didSet { defaults.set(soundEffects, forKey: Key.sounds) } }

    private init() {
        defaults.register(defaults: [
            Key.unlock: true, Key.autoLock: false, Key.autoLockDelay: 30.0, Key.strictness: Strictness.standard.rawValue,
            Key.attention: true, Key.blink: true, Key.externalCamera: false, Key.badge: true, Key.sounds: true,
        ])
        unlockEnabled = defaults.bool(forKey: Key.unlock)
        autoLockEnabled = defaults.bool(forKey: Key.autoLock)
        autoLockDelay = defaults.double(forKey: Key.autoLockDelay)
        strictness = Strictness(rawValue: defaults.integer(forKey: Key.strictness)) ?? .standard
        requireAttention = defaults.bool(forKey: Key.attention)
        requireBlink = defaults.bool(forKey: Key.blink)
        allowExternalCamera = defaults.bool(forKey: Key.externalCamera)
        lockScreenBadge = defaults.bool(forKey: Key.badge)
        soundEffects = defaults.bool(forKey: Key.sounds)
    }

    /// Recognition rules for unlocking.
    var policy: ScanPolicy {
        ScanPolicy(threshold: strictness.threshold, requiredMatches: strictness == .strict ? 3 : 2,
                   requireAttention: requireAttention, requireBlink: requireBlink)
    }
}
