import AppKit
import Combine
import FaceCore

/// FaceID's side of the shared `Updater`: when FaceID is free for a restart, how a new version is offered and how the
/// restart is told. A new version installs itself by default: the updater downloads, checks and stages it in the
/// background and restarts FaceID once `appIsBusy` says FaceID is free, with "Updating to version X…" in the island for a
/// moment; the new copy starts quietly and does not bring out the island. With automatic installs off, a version an
/// automatic check finds is offered in the island (`freshOffer`) when the island is free and nothing important goes on.
/// FaceID never restarts in the middle of something that matters: a download the user started stops when the screen locks
/// or a face scan starts (and is offered again afterwards), and the relaunch at the end waits until FaceID is free, so
/// the new version always starts on the desktop.
@MainActor
final class UpdateCenter {
    static let shared = UpdateCenter()
    let updater = Updater(repo: "tihomirov-nick/faceid")

    private var subscriptions: [AnyCancellable] = []
    private var previous: Updater.State = .idle
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
        // Asked before the restart of an update that installs itself, and again every minute while it says yes.
        updater.appIsBusy = { [weak self] in self?.isBusy ?? false }
        updater.$state.sink { [weak self] state in
            MainActor.assumeIsolated { self?.changed(to: state) }
        }.store(in: &subscriptions)
        // Published before the value is set: the offer looks at the updater on the next turn of the run loop.
        updater.$freshOffer.sink { [weak self] release in
            guard release != nil else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.offer() } }
        }.store(in: &subscriptions)
        NotificationCenter.default.addObserver(forName: Updater.willRestart, object: updater, queue: nil) { [weak self] note in
            MainActor.assumeIsolated { self?.willRestart(note) }
        }
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

    /// Nothing a restart would break: the screen is unlocked, no face is being checked or recorded, no keychain or Touch
    /// ID prompt is up, and the island shows nothing but the update itself (no setup step, no controls, no countdown, no
    /// approval after unlocking).
    var isQuiet: Bool {
        guard !LockScreen.isLocked, AppModel.shared.activeScans == 0, !KeychainPrompt.shared.asking, !Island.shared.keepOpen,
              !Island.lockScreen.isShowing else { return false }
        switch Island.shared.content {
        case nil, .update?, .updating?: return true
        default: return false
        }
    }

    /// What holds back the restart of an update that installs itself: whatever breaks `isQuiet`, and the camera watching
    /// for the owner before the auto-lock (a restart there would leave the Mac unlocked for longer).
    private var isBusy: Bool {
        !isQuiet || AppModel.shared.presence.isWatching
    }

    private func changed(to state: Updater.State) {
        if case .checking = state { return }
        defer { previous = state }
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
        if case .failed = state {
            switch previous {
            case .downloading, .installing:
                // The install failed: the sound, and the page with what went wrong.
                SoundEffects.play(.failure)
                if !Island.shared.isShowing, !LockScreen.isLocked { show() }
            default:
                break
            }
        }
    }

    /// The offer of a version an automatic check found (`freshOffer`, once per version), in the island as soon as the
    /// island is free, the screen is unlocked and nothing important goes on. No sound for it, and it does not take the
    /// keyboard from the app in front.
    private func offer() {
        offerTimer?.invalidate()
        offerTimer = nil
        guard case .available = updater.state else {
            // Installed, skipped or put off meanwhile.
            updater.offerShown()
            return
        }
        guard isQuiet, !Island.shared.isShowing, !AppModel.shared.keychainNeedsConfirmation else {
            let timer = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.offer() }
            }
            RunLoop.main.add(timer, forMode: .common)
            offerTimer = timer
            return
        }
        show()
        updater.offerShown()
    }

    /// An update that installed itself restarts FaceID: said in the island for a moment (`terminationReply` waits for
    /// it), on the desktop and only when the island is free. Never over the lock screen, where FaceID does not restart.
    private func willRestart(_ notification: Notification) {
        guard notification.userInfo?["automatic"] as? Bool == true,
              let release = notification.userInfo?["release"] as? Updater.Release else { return }
        let islandFree: Bool
        switch Island.shared.content {
        case nil, .update?: islandFree = true
        default: islandFree = false
        }
        guard islandFree, isQuiet, !LockScreen.isLocked else { return }
        Island.shared.show(.updating(release.version))
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

    /// The updater relaunches FaceID by quitting it once the new version is in place. On the lock screen or while FaceID
    /// is busy the quit waits (the new version would start on the lock screen, where the keychain must not be asked), and
    /// an automatic restart first lets "Updating to version X…" be read.
    func terminationReply() -> NSApplication.TerminateReply {
        guard case .installing = updater.state else { return .terminateNow }
        let telling = if case .updating? = Island.shared.content { true } else { false }
        guard telling || !isQuiet else { return .terminateNow }
        if !isQuiet { Log.write("update: the relaunch waits until the screen is unlocked and FaceID is free") }
        let asked = Date()
        // A quit that waits runs the run loop in the modal panel mode: the timer has to run in all common modes.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.isQuiet, !telling || Date().timeIntervalSince(asked) >= 1.5 else { return }
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
