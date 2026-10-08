import AppKit
import AudioToolbox
import FaceCore

/// Short sounds for the moments that matter, the same in all the apps of the family. They are macOS's own interface
/// sounds, read from the system at run time and never copied into the app. AudioServices plays them the way macOS plays
/// its interface sounds: at the alert volume, through the device chosen for sound effects, and not at all when
/// interface sound effects are turned off in System Settings. Where this macOS lacks a sound, the classic alert of the
/// same meaning from /System/Library/Sounds plays instead.
@MainActor
enum SoundEffects {
    enum Event: CaseIterable {
        /// It worked, after a while: unlocked by the face, a face recorded, a check passed.
        case success
        /// It did not work: the face not recognized, an error.
        case failure
        /// Something that takes a while begins: the auto-lock countdown.
        case start
        /// A small confirmation: the first circle of the face setup.
        case tick
        case delete
        /// Saved or sent out of the app (FaceID has no such moment yet).
        case sent

        /// The interface sound, and the alert to play when it is missing.
        fileprivate var sound: (path: String, fallback: NSSound.Name) {
            switch self {
            case .success: ("system/head_gestures_double_nod.caf", "Glass")
            case .failure: ("system/head_gestures_double_shake.caf", "Basso")
            case .start: ("system/begin_record.caf", "Tink")
            case .tick: ("system/head_gestures_partial_nod.caf", "Tink")
            case .delete: ("dock/poof item off dock.aif", "Pop")
            case .sent: ("system/SentMessage.caf", "Purr")
            }
        }
    }

    /// Plays `event` unless sound effects are off in the settings. Returns at once.
    static func play(_ event: Event) {
        guard AppSettings.shared.soundEffects else { return }
        player.play(event)
    }

    private static let player = Player()
}

/// Loads each sound once and plays it, off the main thread.
private final class Player: @unchecked Sendable {
    private static let directory = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds")
    private let queue = DispatchQueue(label: "com.faceid.sounds")
    /// Sounds loaded so far; used on `queue` only.
    private var sounds: [SoundEffects.Event: SystemSoundID] = [:]

    func play(_ event: SoundEffects.Event) {
        queue.async { [self] in
            if let sound = sounds[event] ?? load(event) {
                AudioServicesPlaySystemSound(sound)
            } else {
                let fallback = event.sound.fallback
                Log.write("sound \(event): \(event.sound.path) is missing, playing \(fallback)")
                DispatchQueue.main.async { NSSound(named: fallback)?.play() }
            }
        }
    }

    private func load(_ event: SoundEffects.Event) -> SystemSoundID? {
        let url = Self.directory.appendingPathComponent(event.sound.path)
        var sound: SystemSoundID = 0
        guard FileManager.default.fileExists(atPath: url.path),
              AudioServicesCreateSystemSoundID(url as CFURL, &sound) == kAudioServicesNoError else { return nil }
        sounds[event] = sound
        return sound
    }
}
