import AppKit
import Combine
import FaceCore

/// FaceID's side of the shared `Updater`: when to offer a new version, when installing is safe, the sound when it fails.
/// FaceID never restarts in the middle of something that matters: a download stops when the screen locks or a face scan
/// starts (and is offered again afterwards), and the relaunch at the end waits until the screen is unlocked and no face
/// is being checked or recorded, so the new version always starts on the desktop.
@MainActor
final class UpdateCenter {
    static let shared = UpdateCenter()
    let updater = Updater(repo: "tihomirov-nick/faceid")

    private var subscriptions: [AnyCancellable] = []
    private var previous: Updater.State = .idle
    /// The user asked for this check: its answer shows where they are looking (the settings).
    private var userChecking = false
    /// The island shows the answer to "Check for Updates…" from the menu.
    private var showingMenuCheck = false
    /// The download was stopped because of the lock screen or a scan: offered again once that is over.
    private var interrupted = false
    private var offerTimer: Timer?
    private var relaunchTimer: Timer?

    #if DEBUG
    /// Debug hooks: a state to show instead of the updater's.
    static var preview: Updater.State?
    #endif

    /// What the interface shows.
    var state: Updater.State {
        #if DEBUG
        if let preview = Self.preview { return preview }
        #endif
        return updater.state
    }

    func start() {
        updater.$state.sink { [weak self] state in
            MainActor.assumeIsolated { self?.changed(to: state) }
        }.store(in: &subscriptions)
        AppModel.shared.$activeScans.sink { [weak self] scans in
            MainActor.assumeIsolated { if scans > 0 { self?.stopDownload(because: "a face scan started") } }
        }.store(in: &subscriptions)
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopDownload(because: "the screen locked") }
        }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.offerAgainIfInterrupted() }
        }
        updater.start()
    }

    func checkNow() {
        userChecking = true
        updater.check(userInitiated: true)
    }

    /// "Check for Updates…" in the menu bar icon's menu: the answer shows in the island ("up to date" goes away by itself).
    func checkFromMenu() {
        checkNow()
        guard !LockScreen.isLocked else { return }
        showingMenuCheck = true
        show()
    }

    /// A version is being installed: FaceID starts no face check meanwhile (the relaunch would cut it off).
    var isInstalling: Bool {
        if case .installing = updater.state { return true }
        return false
    }

    /// "Update", unless a face is being checked or recorded right now.
    func install() {
        guard isQuiet else {
            AppModel.shared.show(L("Обновить можно, когда не идет проверка или запись лица"))
            return
        }
        updater.install()
    }

    /// The update page. Closed with a click elsewhere while it only offers, it means "Later".
    func show() {
        Island.shared.show(.update) { [weak self] in
            guard let self, case .available = self.updater.state else { return }
            self.updater.dismiss()
        }
    }

    /// Nothing a restart would break: the screen is unlocked, no face is being scanned, and the island shows neither the
    /// face setup, the check, nor a setup step.
    var isQuiet: Bool {
        guard !LockScreen.isLocked, AppModel.shared.activeScans == 0 else { return false }
        switch Island.shared.content {
        case .enroll?, .test?, .password?, .keychain?: return false
        default: return true
        }
    }

    private func changed(to state: Updater.State) {
        if case .checking = state { return }
        defer {
            previous = state
            userChecking = false
        }
        if showingMenuCheck {
            showingMenuCheck = false
            // Nothing newer: said for a moment, then the island goes back into the notch.
            if case .upToDate = state {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, case .upToDate = self.updater.state, case .update? = Island.shared.content else { return }
                        self.updater.dismiss()
                        Island.shared.hide()
                    }
                }
            }
        }
        switch state {
        case .available:
            switch previous {
            case .available, .downloading: return // still offered, or the download was stopped
            default: break
            }
            // An answer to the user's own check shows in the settings; one an automatic check found comes out in the
            // island (after "Later", with the next automatic check).
            if !userChecking { offer() }
        case .failed:
            switch previous {
            case .downloading, .installing:
                // The install failed: the sound, and the page with what went wrong.
                SoundEffects.play(.failure)
                if !Island.shared.isShowing, !LockScreen.isLocked { show() }
            default:
                break
            }
        default:
            break
        }
    }

    /// The offer in the island, as soon as the island is free and nothing important goes on. No sound for it.
    private func offer() {
        offerTimer?.invalidate()
        guard case .available = updater.state else { return }
        guard isQuiet, !Island.shared.isShowing, !AppModel.shared.keychainNeedsConfirmation else {
            let timer = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.offer() }
            }
            RunLoop.main.add(timer, forMode: .common)
            offerTimer = timer
            return
        }
        show()
    }

    private func stopDownload(because reason: String) {
        guard case .downloading = updater.state else { return }
        updater.cancel()
        interrupted = true
        Log.write("update: the download stopped, \(reason)")
    }

    private func offerAgainIfInterrupted() {
        guard interrupted else { return }
        interrupted = false
        offer()
    }

    /// The updater relaunches FaceID by quitting it once the new version is in place. On the lock screen or during a
    /// face scan the quit waits (the new version would start on the lock screen, where the keychain must not be asked).
    func terminationReply() -> NSApplication.TerminateReply {
        guard case .installing = updater.state, !isQuiet else { return .terminateNow }
        Log.write("update: the relaunch waits until the screen is unlocked and no face is being scanned")
        // A quit that waits runs the run loop in the modal panel mode: the timer has to run in all common modes.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.isQuiet else { return }
                timer.invalidate()
                self.relaunchTimer = nil
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        relaunchTimer = timer
        return .terminateLater
    }
}
