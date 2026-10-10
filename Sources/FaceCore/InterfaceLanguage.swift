import AppKit
import Foundation

/// The interface language picked for the app: the Mac's own, Russian or English. It is kept nowhere but in the app's own
/// `AppleLanguages`, the setting System Settings → Language & Region → Applications writes, so a choice made there and one
/// made in the app are the same choice: no list means "Same as System", `["ru"]` Russian, `["en"]` English. macOS reads it
/// once, when the app starts, for its menus, panels and prompts as for the app's own texts, so a new choice takes effect
/// after a restart (`needsRestart`, `relaunch`). Every app of the family carries this very file byte for byte: it has no
/// interface texts and knows nothing about the app, which names the choices in its own words.
///
/// The functions take the defaults and their persistent domain, which go together: `.standard` and the app's bundle
/// identifier unless told otherwise, `UserDefaults(suiteName: name)` and `name` in tests. A process without a bundle
/// identifier (a command line tool, a build without the app bundle) has no domain of its own, and nothing is written.
public enum InterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
    /// The first of the Mac's languages the app speaks, in the order of System Settings; English when it speaks none.
    case system
    case russian = "ru"
    case english = "en"

    public var id: String { rawValue }

    /// "ru" or "en"; nil for `.system`.
    public var code: String? { self == .system ? nil : rawValue }

    /// The localizations of every app of the family.
    private static let localizations = ["en", "ru"]
    private static let key = "AppleLanguages"

    // MARK: The choice

    /// The choice saved for the app. A list that starts with a language the app does not speak ("de", written by hand)
    /// shows as "Same as System"; what the next launch makes of it, `nextLaunch` tells.
    public static func saved(in defaults: UserDefaults = .standard,
                             domain: String? = Bundle.main.bundleIdentifier) -> InterfaceLanguage {
        guard let first = ownLanguages(in: defaults, domain: domain)?.first else { return .system }
        return code(of: first).flatMap(InterfaceLanguage.init(rawValue:)) ?? .system
    }

    /// Saves `choice`: "Same as System" removes the app's `AppleLanguages`, a language writes `[code]`. Only the app's own
    /// domain changes, never the Mac's list of languages.
    public static func save(_ choice: InterfaceLanguage, in defaults: UserDefaults = .standard,
                            domain: String? = Bundle.main.bundleIdentifier) {
        guard domain != nil else { return }
        if let code = choice.code {
            defaults.set([code], forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: Languages of launches

    /// "ru" or "en": the language macOS picked for this launch. It stays until the app quits, whatever is saved meanwhile.
    public static var running: String {
        Bundle.main.preferredLocalizations.first.flatMap(code(of:)) ?? "en"
    }

    /// "ru" or "en" the next launch will speak. macOS takes the app's own list of languages when there is one and the
    /// Mac's otherwise, and picks the first language the app speaks.
    public static func nextLaunch(in defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier,
                                  systemLanguages: [String] = InterfaceLanguage.systemLanguages) -> String {
        let own = ownLanguages(in: defaults, domain: domain) ?? []
        return language(for: own.isEmpty ? systemLanguages : own)
    }

    /// Whether the next launch will speak another language than this one: Settings then offers a restart. `running` is
    /// the language the app shows now (its `Localization.current`).
    public static func needsRestart(running: String = InterfaceLanguage.running, in defaults: UserDefaults = .standard,
                                    domain: String? = Bundle.main.bundleIdentifier,
                                    systemLanguages: [String] = InterfaceLanguage.systemLanguages) -> Bool {
        // Without a domain of its own nothing is saved, and a restart would change nothing.
        guard domain != nil else { return false }
        return nextLaunch(in: defaults, domain: domain, systemLanguages: systemLanguages) != running
    }

    /// "ru" or "en" for these languages, first choice first: the first one the app speaks, English when it speaks none.
    /// For the Mac's languages it is what "Same as System" gives: English for ("en-US", "ru-US"), Russian for ("de-DE",
    /// "ru-RU").
    public static func language(for preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: localizations, forPreferences: preferences).first.flatMap(code(of:)) ?? "en"
    }

    /// The Mac's languages, first choice first: the user's list, or else the one the Mac was set up with. Never the app's
    /// own list, which `Locale.preferredLanguages` gives in their place, so that is the last resort.
    public static var systemLanguages: [String] {
        if let languages = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? [String],
           !languages.isEmpty {
            return languages
        }
        if let languages = CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesAnyUser,
                                                  kCFPreferencesAnyHost) as? [String], !languages.isEmpty {
            return languages
        }
        return Locale.preferredLanguages
    }

    // MARK: Restart

    /// Quits the app the way the user does and opens it again once this process is gone. The quit goes through
    /// `NSApp.terminate`, so the app's delegate has its say: it may let work finish first or ask about unsaved changes.
    /// If the app stays after all, the helper waiting for it stops, and nothing opens later. Whether a restart may happen
    /// now (not while the app is busy) is the app's to decide. Without an app bundle there is nothing to open, and the
    /// app keeps running.
    @MainActor public static func relaunch() {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { return }
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = relaunchArguments(pid: ProcessInfo.processInfo.processIdentifier, app: app,
                                             bundleID: Bundle.main.bundleIdentifier ?? "")
        waiter.standardInput = FileHandle.nullDevice
        waiter.standardOutput = FileHandle.nullDevice
        waiter.standardError = FileHandle.nullDevice
        do { try waiter.run() } catch { return }
        // A quit that goes through never brings the run loop back to the default mode: this runs only if the app stays.
        RunLoop.main.perform(inModes: [.default]) {
            if waiter.isRunning { waiter.terminate() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        NSApp.terminate(nil)
    }

    /// Arguments for /bin/sh that wait for process `pid` to end, then open the app at `app`, or the app with `bundleID`
    /// when nothing is left there (an update installed at the quit went elsewhere).
    static func relaunchArguments(pid: Int32, app: URL, bundleID: String, open: String = "/usr/bin/open") -> [String] {
        let script = """
            while kill -0 "$0" 2>/dev/null; do sleep 0.1; done
            [ -d "$1" ] && exec "$3" "$1"
            [ -n "$2" ] && exec "$3" -b "$2"
            """
        return ["-c", script, String(pid), app.path, bundleID, open]
    }

    // MARK: Earlier settings

    /// Moves the language an app kept under keys of its own before the family standard into `AppleLanguages`, then
    /// removes those keys. `choiceKey` holds the old choice: "ru" or "en", anything else counts as automatic.
    /// `appliedKey` holds the language the app last wrote into `AppleLanguages` by itself. A list written for automatic
    /// goes, a language picked by hand stays as `[code]`. A list that changed after the app last wrote it (another
    /// language, or none at all) was changed in System Settings, and that later choice stays as it is. Call it at launch
    /// before anything asks the bundle for its localizations: the bundle answers once per launch.
    public static func migrate(choiceKey: String, appliedKey: String, in defaults: UserDefaults = .standard,
                               domain: String? = Bundle.main.bundleIdentifier) {
        guard let domain, let values = defaults.persistentDomain(forName: domain),
              values[choiceKey] != nil || values[appliedKey] != nil else { return }
        let written = (values[key] as? [String])?.first.map(base)
        let applied = (values[appliedKey] as? String).map(base)
        // Still the list the app wrote itself (or no list, and none written): the old choice decides.
        if written == applied {
            let picked = (values[choiceKey] as? String).flatMap(code(of:)).flatMap(InterfaceLanguage.init(rawValue:))
            save(picked ?? .system, in: defaults, domain: domain)
        }
        defaults.removeObject(forKey: choiceKey)
        defaults.removeObject(forKey: appliedKey)
    }

    // MARK: Helpers

    /// The app's own list of languages, as System Settings or `save` wrote it; nil when there is none.
    private static func ownLanguages(in defaults: UserDefaults, domain: String?) -> [String]? {
        guard let domain else { return nil }
        return defaults.persistentDomain(forName: domain)?[key] as? [String]
    }

    /// The language of an identifier without its region or script: "ru" for "ru-RU" and "ru_RU".
    private static func base(_ identifier: String) -> String {
        identifier.prefix { $0 != "-" && $0 != "_" }.lowercased()
    }

    /// "ru" or "en" for an identifier of either language ("ru", "en-GB"); nil for any other language.
    private static func code(of identifier: String) -> String? {
        let language = base(identifier)
        return localizations.contains(language) ? language : nil
    }
}
