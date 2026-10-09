import AppKit
import Foundation
import ServiceManagement

/// What `Updater.LoginItem` asks of SMAppService.mainApp. The test harness hands in a stand-in, so that nothing is
/// registered for real.
protocol UpdaterLoginService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: UpdaterLoginService {}

/// Opening the app at login. Part of `Updater`, carried byte for byte by every app of the family like Updater.swift.
extension Updater {
    /// The app opens at login through SMAppService.mainApp. `Updater.start` switches it on once for a copy in an
    /// Applications folder (`applyDefault`), unless the user has switched it off, and from then on it stays as the user
    /// sets it: the app's own switch reads `isEnabled` and calls `set`, which remembers the choice, so the default never
    /// comes back over it; switching it off in System Settings counts as well. A copy that takes over from another one (a
    /// move, an update put into another folder) registers again from its own place (`registerAgain`).
    @MainActor final class LoginItem: ObservableObject {
        static let shared = LoginItem()

        init(service: UpdaterLoginService = SMAppService.mainApp, defaults: UserDefaults = .standard) {
            self.service = service
            self.defaults = defaults
            isEnabled = service.status == .enabled
        }

        /// The app opens at login.
        @Published private(set) var isEnabled: Bool

        /// Registered but switched off in System Settings › General › Login Items: only the user can switch it on there
        /// (`openSystemSettings()`), `set(true)` cannot.
        var needsApproval: Bool { service.status == .requiresApproval }

        /// What the user chose with `set`; nil while the default stands.
        var choice: Bool? { defaults.object(forKey: Keys.choice) as? Bool }

        /// The user's choice, from the app's settings: remembered, then applied.
        func set(_ on: Bool) {
            defaults.set(on, forKey: Keys.choice)
            apply(on, because: "the user's choice")
        }

        /// Reads the state again: System Settings may have changed it (for when the app's settings open).
        func refresh() {
            let enabled = service.status == .enabled
            if enabled != isEnabled { isEnabled = enabled }
        }

        /// System Settings › General › Login Items.
        func openSystemSettings() {
            SMAppService.openSystemSettingsLoginItems()
        }

        /// Switches the login item on once per user, unless the user has made a choice or switched it off in System
        /// Settings; later launches leave it as it is, whatever has happened to it meanwhile.
        func applyDefault() {
            guard !defaults.bool(forKey: Keys.defaultApplied) else { return }
            defaults.set(true, forKey: Keys.defaultApplied)
            guard choice == nil else { return }
            switch service.status {
            case .enabled:
                refresh()
            case .requiresApproval:
                Updater.log("Opening at login is switched off in System Settings: it stays so")
            default:
                apply(true, because: "on by default")
            }
        }

        /// This copy has taken over from one that opened at login: registered again from here, so that the login opens
        /// this copy and not the one left behind (in the Trash, on a detached disk image). The user's choice stays.
        func registerAgain() {
            try? service.unregister()
            do {
                try service.register()
                Updater.log("Login item registered again for \(Bundle.main.bundleURL.path)")
            } catch {
                Updater.log("Cannot register the login item again: \(error.localizedDescription) (status \(service.status.rawValue))")
            }
            refresh()
        }

        /// Started by the login item, so that a windowed app starts without a window and without a Dock icon: macOS marks
        /// the launch (a login item of the classic kind), or the user's session began less than two minutes ago while the
        /// app opens at login (SMAppService leaves no mark), or an automatic update has just brought back a copy that ran
        /// without a Dock icon. Read it while the app launches (`applicationWillFinishLaunching`,
        /// `applicationDidFinishLaunching`, or `Updater.start` called there): the launch event is gone afterwards.
        static let launchedAtLogin: Bool = {
            let event = NSAppleEventManager.shared().currentAppleEvent
            return startedAtLogin(marked: event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem,
                                  relaunchedQuietly: Updater.takeQuietRelaunch(for: Bundle.main.bundleURL),
                                  sessionAge: consoleSessionAge(), opensAtLogin: SMAppService.mainApp.status == .enabled)
        }()

        nonisolated static func startedAtLogin(marked: Bool, relaunchedQuietly: Bool, sessionAge: TimeInterval?,
                                               opensAtLogin: Bool) -> Bool {
            if marked || relaunchedQuietly { return true }
            guard opensAtLogin, let age = sessionAge else { return false }
            return age >= 0 && age < 120
        }

        /// How long ago this user logged in at the console; nil when it cannot be told.
        nonisolated static func consoleSessionAge(now: Date = Date()) -> TimeInterval? {
            var login: Date?
            setutxent()
            defer { endutxent() }
            while let entry = getutxent() {
                let record = entry.pointee
                guard record.ut_type == USER_PROCESS else { continue }
                let user = withUnsafeBytes(of: record.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                let line = withUnsafeBytes(of: record.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if user == NSUserName(), line == "console" {
                    login = Date(timeIntervalSince1970: Double(record.ut_tv.tv_sec))
                }
            }
            return login.map { now.timeIntervalSince($0) }
        }

        private let service: UpdaterLoginService
        private let defaults: UserDefaults

        private enum Keys {
            static let choice = "openAtLoginChoice"
            static let defaultApplied = "openAtLoginDefaultApplied"
        }

        private func apply(_ on: Bool, because reason: String) {
            do {
                if on { try service.register() } else { try service.unregister() }
                Updater.log(on ? "Opens at login (\(reason))" : "Does not open at login any more (\(reason))")
            } catch {
                Updater.log("Cannot \(on ? "register" : "unregister") the login item (\(reason)): \(error.localizedDescription) "
                            + "(status \(service.status.rawValue))")
            }
            refresh()
        }
    }

    // MARK: Quiet restart

    private nonisolated static let quietRelaunchKey = "UpdaterQuietRelaunch"

    /// An automatic update restarts a copy that ran without a Dock icon: the new process starts the same way.
    nonisolated static func recordQuietRelaunch(of app: URL, in defaults: UserDefaults = .standard, now: Date = Date()) {
        defaults.set(["app": app.path, "time": now.timeIntervalSince1970], forKey: quietRelaunchKey)
        // The process quits in a moment.
        defaults.synchronize()
    }

    /// The record of a quiet restart, read once: it counts for the copy at `bundle` within two minutes.
    nonisolated static func takeQuietRelaunch(for bundle: URL, in defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        guard let record = defaults.dictionary(forKey: quietRelaunchKey) else { return false }
        defaults.removeObject(forKey: quietRelaunchKey)
        guard let path = record["app"] as? String, let time = record["time"] as? Double else { return false }
        return same(URL(fileURLWithPath: path), bundle) && abs(now.timeIntervalSince1970 - time) < 120
    }
}
