import AppKit
import Foundation
import Network
import Security

/// Updates the app from its releases on GitHub. It looks for a newer release by itself: right after launch (as soon as
/// the network is up), every 3 hours, and after a wake or when the app comes to the front once an hour has passed since
/// the last look, each time a few random minutes later, so that the apps of the family never ask together; GitHub is
/// asked with the ETag of its last answer, and "nothing new" costs nothing of its hourly limit. A newer release installs
/// itself by default (`automaticInstall`): its DMG is downloaded, the app inside is checked to be signed by the same
/// certificate as the running copy and staged in place, and the app restarts as soon as it is free (`appIsBusy`), or the
/// new version goes in when the user quits it. Otherwise the release is offered (`freshOffer`) and installed by "Update".
/// The app lives in /Applications, or in ~/Applications when this user may not write to /Applications: a copy started
/// anywhere else (an open DMG, a translocated copy, Downloads) moves itself there at launch, and an update that cannot
/// replace the running copy goes there as well (see Updater+Placement.swift). The app opens at login unless the user
/// says otherwise (see Updater+LoginItem.swift). None of it asks anything; the reasons of every detour go to the app's
/// log. Every app of the family carries this very file, Updater+Placement.swift and Updater+LoginItem.swift, byte for
/// byte: they have no interface texts and know nothing about the app, which shows the states in its own words and style.
@MainActor final class Updater: ObservableObject {
    struct Release: Equatable {
        /// The tag without "v".
        let version: String
        let title: String
        /// The release text as written on GitHub (Markdown).
        let notes: String
        let page: URL
        let dmg: URL
        let size: Int64
    }

    enum Failure: Error, Equatable {
        /// GitHub could not be reached or answered something unreadable.
        case offline
        /// GitHub refused: too many requests from this address (403, 429).
        case rateLimited
        /// The newer release has no DMG.
        case noInstaller
        /// The download broke off.
        case download
        /// The DMG is not what the release promised: wrong size, does not open, no newer app inside.
        case damaged
        /// The app inside is another app or is signed by another certificate than the running copy.
        case notTrusted
        /// The new version could be put neither over the running copy nor into an Applications folder: a development
        /// build, or an unexpected error written to the app's log. The downloaded DMG can be opened in Finder instead,
        /// see `openReleasePage()`.
        case cannotReplace
    }

    enum State: Equatable {
        case idle, checking, upToDate, available(Release), downloading(Release, progress: Double), installing(Release),
             failed(Failure, Release?)
    }

    /// What the automatic checks take from the world around them. The apps leave it as it is; the test harness drives a
    /// clock of its own and stands in for the network.
    struct Environment {
        var now: () -> Date = { Date() }
        /// Calls `fire` once at `date` on the main thread, not while a menu is open or a modal panel waits for an
        /// answer; the returned closure cancels it.
        var timer: (Date, @escaping @MainActor () -> Void) -> () -> Void = Environment.runLoopTimer
        /// The random delay of an automatic check.
        var jitter: () -> TimeInterval = { .random(in: 0...300) }
        /// Watches the network: `changed(true)` when it is up (at once when it is up already), `changed(false)` when it
        /// goes away. The result keeps the watch going.
        var watchNetwork: (@escaping @MainActor (Bool) -> Void) -> AnyObject? = Environment.pathMonitor
        /// Stands in for `isDevelopmentBuild` (the test harness is no app bundle).
        var developmentBuild: Bool?

        static func runLoopTimer(at date: Date, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
            let timer = Timer(fire: date, interval: 0, repeats: false) { _ in MainActor.assumeIsolated { fire() } }
            RunLoop.main.add(timer, forMode: .default)
            return { timer.invalidate() }
        }

        static func pathMonitor(_ changed: @escaping @MainActor (Bool) -> Void) -> AnyObject? {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                let up = path.status == .satisfied
                DispatchQueue.main.async { MainActor.assumeIsolated { changed(up) } }
            }
            monitor.start(queue: DispatchQueue(label: "Updater.network"))
            return monitor
        }
    }

    /// `loginItem`: `LoginItem.shared` unless the test harness gives a stand-in.
    init(repo: String, apiBase: URL = URL(string: "https://api.github.com")!, loginItem: LoginItem? = nil,
         environment: Environment = Environment()) {
        self.repo = repo
        self.apiBase = apiBase
        self.loginItem = loginItem ?? .shared
        self.environment = environment
    }

    @Published private(set) var state: State = .idle

    /// A newer version an automatic check has just found and offers, because `automaticInstall` is off or the update
    /// cannot install itself: the app shows it where it is seen (a window, a notification, a badge) and calls
    /// `offerShown()`. It comes once per version: never for a skipped version, nor for one put off with "Later" before
    /// its 24 hours are over, nor again for a version shown already (a check the user asked for shows it too).
    /// `didFindUpdate` is posted along with it.
    @Published private(set) var freshOffer: Release?

    /// Posted when `freshOffer` is set: the object is the updater, `userInfo["release"]` the `Release`.
    static let didFindUpdate = Notification.Name("UpdaterDidFindUpdate")

    /// Posted right before the app is asked to quit and come back as the new version, `state` being `.installing` by
    /// then: `userInfo["release"]` is the `Release`, `userInfo["automatic"]` is true when the update installed itself and
    /// false after "Update".
    static let willRestart = Notification.Name("UpdaterWillRestart")

    /// The app has shown `freshOffer`.
    func offerShown() {
        freshOffer = nil
    }

    /// Whether the app is in the middle of something a restart would break: an export, a recognition, a capture, a face
    /// scan, unsaved work. An update that installs itself restarts the app only when this says no and no menu, modal
    /// panel or sheet is open, and asks again every minute until then; a quit the user makes meanwhile puts the new
    /// version in place. The quit itself goes through the app's `applicationShouldTerminate`, as after "Update".
    var appIsBusy: () -> Bool = { false }

    /// Opening at login; the same object as `LoginItem.shared` in the apps.
    let loginItem: LoginItem

    /// Automatic checks; on by default.
    var automaticChecks: Bool {
        get { UserDefaults.standard.object(forKey: Keys.automaticChecks) as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Keys.automaticChecks)
            scheduleChecks()
        }
    }

    /// A newer version an automatic check finds installs itself: downloaded, checked and staged in the background, put
    /// in place when the app restarts as soon as it is free (see `appIsBusy`) or when the user quits it. On by default; off,
    /// the automatic check offers it instead (`freshOffer`). A failure goes only to the log and the next check tries
    /// again; after the second one the version is offered.
    var automaticInstall: Bool {
        get { UserDefaults.standard.object(forKey: Keys.automaticInstall) as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Keys.automaticInstall)
            // Switched off on the way: the version is offered instead, and nothing staged goes in by itself.
            if !newValue {
                let release = auto?.release
                dropAutomaticUpdate(all: true)
                if let release, state == .idle { state = .available(release) }
            }
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// A copy built from the sources (in build/ next to Package.swift, or not an app bundle at all): it never checks by
    /// itself, never moves and never replaces itself.
    var isDevelopmentBuild: Bool { environment.developmentBuild ?? Self.isDevelopmentBuild(Bundle.main.bundleURL) }

    /// An update installs itself: over the running copy, or into an Applications folder when the running copy cannot be
    /// replaced where it is (translocated, on a read-only volume, in a folder this user may not write to). False for a
    /// development build, and when no Applications folder can be written either.
    var installsByItself: Bool { !isDevelopmentBuild && !installTargets.isEmpty }

    /// The former name of `installsByItself`, from when an update could only replace the running copy.
    var canInstallInPlace: Bool { installsByItself }

    /// The version an update that installs itself is working on, and whether it is staged and waits for the restart (or
    /// the next quit); a view observing the updater follows it.
    var automaticUpdate: (release: Release, ready: Bool)? { auto.map { ($0.release, $0.ready) } }

    /// Starts the automatic checks: one right away (as soon as the network is up), then every 3 hours, and after a wake
    /// or when the app comes to the front once an hour has passed. Before that a copy that has just taken over from
    /// another one finishes the handoff, and a copy started outside the Applications folders moves there (or switches to
    /// the copy installed there) and restarts, with no checks meanwhile; a copy in an Applications folder opens at login
    /// from now on unless the user has said otherwise (`LoginItem.applyDefault`). `folders` are where the app is
    /// installed, best first: the apps leave them as they are, the test harness gives its own. Called while the app
    /// launches, it also catches `LoginItem.launchedAtLogin` in time.
    func start(applicationFolders folders: [URL] = Updater.applicationFolders) {
        guard !started else { return }
        started = true
        self.folders = folders
        _ = LoginItem.launchedAtLogin
        try? FileManager.default.removeItem(at: Self.updatesFolder)
        if !isDevelopmentBuild {
            watch()
            let handoff = Self.takeHandoff(to: origin.url)
            if let handoff { Self.finish(handoff, loginItem: loginItem) }
            if settle(after: handoff) { return }
            if isInstalled { loginItem.applyDefault() }
        }
        scheduleChecks()
    }

    /// Asks GitHub for the latest release. `upToDate` and failures are shown only after a check the user asked for. An
    /// automatic check stays silent, leaves alone a skipped version and one put off with "Later", and installs a newer
    /// version by itself (`automaticInstall`) or offers it (`freshOffer`).
    func check(userInitiated: Bool) {
        check(userInitiated ? .user : .app)
    }

    /// Downloads the offered release, checks it, puts it in place and relaunches.
    func install() {
        let release: Release
        switch state {
        case .available(let offered): release = offered
        case .failed(_, let offered?): release = offered
        default: return
        }
        guard !relocating else { return }
        guard !isDevelopmentBuild else {
            state = .failed(.cannotReplace, release)
            return
        }
        if freshOffer?.version == release.version { freshOffer = nil }
        // In place already (staged by an update that installs itself, or waiting for a quit the app refused): only the
        // other copies and the quit are left.
        if let next = pendingRestart, next.version == release.version,
           FileManager.default.fileExists(atPath: next.staged?.copy.path ?? next.app.path) {
            if let job = auto {
                job.stopWaiting?()
                job.download?.cancel()
                auto = nil
            }
            state = .installing(release)
            Task { await self.finish(next, release: release, automatic: false) }
            return
        }
        dropAutomaticUpdate()
        keptInstaller = nil
        state = .downloading(release, progress: 0)
        startDownload(release)
    }

    /// Never offers or installs this version or an older one by itself again (a check the user asks for still shows it).
    func skip() {
        switch state {
        case .available(let release), .failed(_, let release?):
            UserDefaults.standard.set(release.version, forKey: Keys.skippedVersion)
            if auto?.release.version == release.version { dropAutomaticUpdate() }
            if pendingRestart?.version == release.version {
                if let staged = pendingRestart?.staged { try? FileManager.default.removeItem(at: staged.folder) }
                pendingRestart = nil
            }
            if freshOffer?.version == release.version { freshOffer = nil }
            Self.log("\(release.version) skipped")
            state = .idle
        default: break
        }
    }

    /// "Later": an automatic check offers this version again after 24 hours (a newer one at once), and an update that
    /// installs itself leaves it alone as long; a check the user asks for shows it any time.
    func dismiss() {
        switch state {
        case .available(let release), .failed(_, let release?):
            putOff(release)
            state = .idle
        case .upToDate, .failed:
            state = .idle
        default:
            break
        }
    }

    /// Stops the download; the release stays offered.
    func cancel() {
        guard case .downloading(let release, _) = state else { return }
        downloadID = nil
        download?.cancel()
        download = nil
        state = .available(release)
    }

    /// The release page on GitHub. After `cannotReplace` it opens the downloaded DMG in Finder instead, so the app can be
    /// dragged into place by hand.
    func openReleasePage() {
        if case .failed(.cannotReplace, _) = state, let dmg = keptInstaller, FileManager.default.fileExists(atPath: dmg.path) {
            NSWorkspace.shared.open(dmg)
        } else {
            NSWorkspace.shared.open(releasePage)
        }
    }

    // MARK: - Checking

    /// Between two automatic checks.
    nonisolated static let checkInterval: TimeInterval = 3 * 60 * 60
    /// A wake or the app coming to the front brings a check once this much has passed since the last one.
    nonisolated static let wakeGap: TimeInterval = 60 * 60
    /// The next try after GitHub could not be reached; sooner when the network comes back.
    nonisolated static let retryInterval: TimeInterval = 10 * 60
    /// How long "Later" puts a version off.
    nonisolated static let laterInterval: TimeInterval = 24 * 60 * 60
    /// How often an update that waits for the app to be free asks again.
    nonisolated static let busyInterval: TimeInterval = 60
    /// Failures after which a version is offered instead of installing itself.
    nonisolated static let automaticAttempts = 2

    private let repo: String
    private let apiBase: URL
    private let environment: Environment
    private var started = false
    /// Where the app is installed, best first (see `start`).
    private var folders = Updater.applicationFolders
    /// The page of the latest release seen, for a failure that has no release to show.
    private var latestPage: URL?
    /// A request to GitHub is under way.
    private(set) var inFlight = false
    /// The user asked for a check while an automatic one was under way: its answer is theirs.
    private var userWaiting = false
    /// When the last check started.
    private(set) var lastAttempt: Date?
    /// When the next automatic check runs.
    private(set) var nextCheck: Date?
    private var cancelNextCheck: (() -> Void)?
    /// GitHub refused for too many requests: no automatic check before this.
    private(set) var backoffUntil: Date?
    /// The network as the system sees it; nil until it says.
    private var networkUp: Bool?
    /// The check that runs as soon as the network is up: the first one, or another try after GitHub could not be reached.
    private var waitingForNetwork: Trigger?
    private var observers: [NSObjectProtocol] = []
    private var networkWatch: AnyObject?

    private enum Keys {
        static let automaticChecks = "checkForUpdates"
        static let automaticInstall = "installUpdatesAutomatically"
        static let skippedVersion = "skippedUpdateVersion"
        static let laterVersion = "laterUpdateVersion"
        static let laterUntil = "laterUpdateUntil"
        static let shownVersion = "shownUpdateVersion"
        static let cachedAnswer = "updateCheckCache"
    }

    /// What made a check run, for the log.
    private enum Trigger: String {
        case user, app, launch, timer, wake, activation, network
    }

    private var appName: String { Self.appName }

    private var releasePage: URL {
        switch state {
        case .available(let release), .downloading(let release, _), .installing(let release), .failed(_, let release?):
            return release.page
        default:
            return latestPage ?? URL(string: "https://github.com/\(repo)/releases/latest")!
        }
    }

    /// Automatic checks run: switched on, not a development build, and the app is not about to restart from elsewhere.
    private var automaticChecksRun: Bool { started && !relocating && automaticChecks && !isDevelopmentBuild }

    /// The running copy lies in one of the Applications folders.
    private var isInstalled: Bool {
        let readOnly = (try? origin.url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
        return Self.place(of: origin.url, translocated: origin.translocated, readOnly: readOnly, folders: folders) == .installed
    }

    /// (Re)starts the automatic checks with one right away, or as soon as the network is up: at launch, when the switch
    /// is turned on, after a move that did not happen. Switched off, they stop, and so does an update that installs itself.
    private func scheduleChecks() {
        cancelNextCheck?()
        cancelNextCheck = nil
        nextCheck = nil
        waitingForNetwork = nil
        guard started, automaticChecksRun else {
            if !automaticChecks { dropAutomaticUpdate(all: true) }
            return
        }
        // In case the network never says it is up.
        armCheck(at: environment.now() + Self.checkInterval + environment.jitter(), .timer)
        if networkUp == true {
            automaticCheck(.launch)
        } else {
            waitingForNetwork = .launch
        }
    }

    /// A wake, the app coming to the front and the network coming back bring checks of their own.
    private func watch() {
        guard observers.isEmpty else { return }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack(.wake) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack(.activation) }
        })
        networkWatch = environment.watchNetwork { [weak self] up in self?.networkChanged(up: up) }
    }

    /// After a wake or when the app comes to the front: a check a few minutes later, once an hour has passed since the
    /// last one.
    private func cameBack(_ trigger: Trigger) {
        // The first check waits for the network: it runs as soon as the network is up.
        guard automaticChecksRun, !inFlight, waitingForNetwork != .launch else { return }
        let now = environment.now()
        if let end = backoffUntil, now < end { return }
        if let last = lastAttempt, now.timeIntervalSince(last) < Self.wakeGap { return }
        let at = now + environment.jitter()
        if let next = nextCheck, next <= at { return }
        armCheck(at: at, trigger)
    }

    /// What the network watch says; the test harness says it by hand.
    func networkChanged(up: Bool) {
        let was = networkUp
        networkUp = up
        guard up, was != true, let trigger = waitingForNetwork, automaticChecksRun else { return }
        waitingForNetwork = nil
        automaticCheck(trigger)
    }

    private func armCheck(at date: Date, _ trigger: Trigger) {
        cancelNextCheck?()
        cancelNextCheck = nil
        nextCheck = nil
        guard automaticChecksRun else { return }
        nextCheck = date
        cancelNextCheck = environment.timer(date) { [weak self] in
            guard let self else { return }
            self.cancelNextCheck = nil
            self.nextCheck = nil
            self.automaticCheck(trigger)
        }
    }

    private func automaticCheck(_ trigger: Trigger) {
        guard automaticChecksRun else { return }
        let now = environment.now()
        if let end = backoffUntil, now < end {
            if nextCheck == nil { armCheck(at: end + environment.jitter(), .timer) }
            return
        }
        switch state {
        case .checking, .downloading, .installing:
            // The user is at it: the automatic check comes later.
            if nextCheck == nil { armCheck(at: now + Self.checkInterval + environment.jitter(), .timer) }
            return
        default:
            break
        }
        check(trigger)
    }

    private func check(_ trigger: Trigger) {
        let user = trigger == .user
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        guard !relocating, user || (automaticChecks && !isDevelopmentBuild) else { return }
        if user { state = .checking }
        guard !inFlight else {
            // One request at a time: the automatic one under way answers the user.
            if user { userWaiting = true }
            return
        }
        inFlight = true
        lastAttempt = environment.now()
        Task { [weak self] in
            guard let self else { return }
            let answer = await self.askGitHub()
            self.inFlight = false
            let userInitiated = user || self.userWaiting
            self.userWaiting = false
            self.apply(answer, trigger: trigger, userInitiated: userInitiated)
        }
    }

    /// What the latest release on GitHub means for this copy.
    enum Latest: Equatable {
        /// No releases yet, or the latest one is not newer.
        case nothingNewer
        case newer(Release)
        /// Newer, but there is no DMG to install.
        case noInstaller(page: URL)
    }

    private enum Answer {
        /// `notModified`: GitHub answered 304, and its last full answer was read again.
        case latest(Latest, notModified: Bool)
        /// `until`: when GitHub takes requests again, as far as it says.
        case failed(Failure, until: Date?)
    }

    /// The last full answer of GitHub with its ETag, kept across launches: asked with it, GitHub answers 304 when the
    /// latest release has not changed, and such an answer does not count against the hourly limit.
    private struct CachedAnswer {
        let url: String
        let etag: String
        let body: Data

        static func load(for url: URL) -> CachedAnswer? {
            guard let record = UserDefaults.standard.dictionary(forKey: Keys.cachedAnswer),
                  record["url"] as? String == url.absoluteString, let etag = record["etag"] as? String,
                  let body = record["body"] as? Data else { return nil }
            return CachedAnswer(url: url.absoluteString, etag: etag, body: body)
        }

        func save() {
            UserDefaults.standard.set(["url": url, "etag": etag, "body": body], forKey: Keys.cachedAnswer)
        }

        static func forget() {
            UserDefaults.standard.removeObject(forKey: Keys.cachedAnswer)
        }
    }

    private func askGitHub() async -> Answer {
        let url = apiBase.appendingPathComponent("repos/\(repo)/releases/latest")
        let cached = CachedAnswer.load(for: url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        // A 304 with nothing to read again (it should not happen) asks once more, without the ETag.
        for conditional in [cached != nil, false] {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("\(appName)/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            if conditional, let cached { request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
            guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
                return .failed(.offline, until: nil)
            }
            switch http.statusCode {
            case 200:
                guard let latest = Self.latest(from: data, appName: appName, current: currentVersion) else {
                    return .failed(.offline, until: nil)
                }
                if let etag = http.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
                    CachedAnswer(url: url.absoluteString, etag: etag, body: data).save()
                } else {
                    CachedAnswer.forget()
                }
                return .latest(latest, notModified: false)
            case 304:
                if conditional, let cached, let latest = Self.latest(from: cached.body, appName: appName, current: currentVersion) {
                    return .latest(latest, notModified: true)
                }
                CachedAnswer.forget()
            case 404:
                CachedAnswer.forget()
                return .latest(.nothingNewer, notModified: false)
            case 403, 429:
                return .failed(.rateLimited, until: Self.rateLimitEnd(of: http, now: environment.now()))
            default:
                return .failed(.offline, until: nil)
            }
        }
        return .failed(.offline, until: nil)
    }

    /// When GitHub takes requests again after a 403 or 429: Retry-After, or the reset of a used-up limit; nil when it
    /// does not say. Kept between a minute and a day away.
    nonisolated static func rateLimitEnd(of response: HTTPURLResponse, now: Date) -> Date? {
        var end: Date?
        if let text = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(text.trimmingCharacters(in: .whitespaces)) {
            end = now.addingTimeInterval(seconds)
        }
        if response.value(forHTTPHeaderField: "X-RateLimit-Remaining")?.trimmingCharacters(in: .whitespaces) == "0",
           let text = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let reset = TimeInterval(text.trimmingCharacters(in: .whitespaces)) {
            end = max(end ?? .distantPast, Date(timeIntervalSince1970: reset))
        }
        return end.map { min(max($0, now.addingTimeInterval(60)), now.addingTimeInterval(24 * 60 * 60)) }
    }

    /// One line of the log for every check: what GitHub said, what came of it, and when the next try is after a failure.
    private func apply(_ answer: Answer, trigger: Trigger, userInitiated: Bool) {
        let retry = reschedule(after: answer)
        var found: String
        switch answer {
        case .latest(.newer(let release), _): found = "\(release.version) is out"
        case .latest(.noInstaller, _): found = "a newer release has no installer"
        case .latest(.nothingNewer, _): found = "nothing newer than \(currentVersion)"
        case .failed(.rateLimited, _): found = "GitHub refused, too many requests"
        case .failed: found = "GitHub could not be reached"
        }
        if case .latest(_, notModified: true) = answer { found += " (not modified)" }
        let outcome = decide(answer, userInitiated: userInitiated)
        let asked = userInitiated && trigger != .user ? ", for the user" : ""
        Self.log("Check (\(trigger.rawValue)\(asked)): \(found)\(outcome.map { ", \($0)" } ?? "")\(retry)")
    }

    /// Arms the next automatic check after an answer; for a failure, says when it comes.
    private func reschedule(after answer: Answer) -> String {
        let now = environment.now()
        switch answer {
        case .latest:
            waitingForNetwork = nil
            backoffUntil = nil
            armCheck(at: now + Self.checkInterval + environment.jitter(), .timer)
            return ""
        case .failed(.rateLimited, let until):
            let end = until ?? now.addingTimeInterval(60 * 60)
            backoffUntil = end
            armCheck(at: end + environment.jitter(), .timer)
            return automaticChecksRun ? "; next check after \(Self.time(end))" : ""
        case .failed:
            if waitingForNetwork == nil { waitingForNetwork = .network }
            let next = now + Self.retryInterval + environment.jitter()
            armCheck(at: next, .timer)
            return automaticChecksRun ? "; next try at \(Self.time(next)) or once the network is back" : ""
        }
    }

    /// The state an answer leads to. An automatic answer changes only an offer; whatever the user is looking at (a check,
    /// a download, an error) stays. Says what came of a newer release, for the log.
    private func decide(_ answer: Answer, userInitiated: Bool) -> String? {
        switch state {
        case .downloading, .installing: return "the update under way goes on"
        case .checking where !userInitiated: return nil
        default: break
        }
        var offered = false
        if case .available = state { offered = true }
        switch answer {
        case .latest(.newer(let release), _):
            latestPage = release.page
            if userInitiated {
                UserDefaults.standard.set(release.version, forKey: Keys.shownVersion)
                state = .available(release)
                return "shown"
            }
            if let reason = putAside(release) {
                if auto?.release.version == release.version { dropAutomaticUpdate() }
                if offered { state = .idle }
                if freshOffer?.version == release.version { freshOffer = nil }
                return reason
            }
            if automaticInstall && installsByItself && automaticFailures[release.version, default: 0] < Self.automaticAttempts {
                if case .available(let shown) = state, shown.version != release.version { state = .idle }
                if let fresh = freshOffer, fresh.version != release.version { freshOffer = nil }
                return installAutomatically(release)
            }
            state = .available(release)
            signal(release)
            guard automaticInstall else { return "offered" }
            return installsByItself ? "offered, it failed to install by itself" : "offered, this copy cannot install it by itself"
        case .latest(.noInstaller(let page), _):
            latestPage = page
            if userInitiated {
                state = .failed(.noInstaller, nil)
            } else if offered {
                state = .idle
            }
            return nil
        case .latest(.nothingNewer, _):
            // The release is gone: what was staged of it goes too.
            dropAutomaticUpdate(all: true)
            freshOffer = nil
            if userInitiated {
                state = .upToDate
            } else if offered {
                state = .idle
            }
            return nil
        case .failed(let failure, _):
            if userInitiated { state = .failed(failure, nil) }
            return nil
        }
    }

    /// Why an automatic check leaves a version alone (skipped, or put off with "Later"); nil when it does not.
    private func putAside(_ release: Release) -> String? {
        let defaults = UserDefaults.standard
        if let skipped = defaults.string(forKey: Keys.skippedVersion), Self.compare(release.version, skipped) != .orderedDescending {
            return "skipped by the user"
        }
        if defaults.string(forKey: Keys.laterVersion) == release.version {
            let until = Date(timeIntervalSince1970: defaults.double(forKey: Keys.laterUntil))
            if environment.now() < until { return "put off until \(Self.time(until))" }
        }
        return nil
    }

    /// The offer of an automatic check made noticeable, once per version (see `freshOffer`).
    private func signal(_ release: Release) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Keys.shownVersion) != release.version else { return }
        defaults.set(release.version, forKey: Keys.shownVersion)
        freshOffer = release
        NotificationCenter.default.post(name: Self.didFindUpdate, object: self, userInfo: ["release": release])
    }

    /// "Later" for `release`. What an update that installs itself has staged stays, and goes in at the next quit.
    private func putOff(_ release: Release) {
        let defaults = UserDefaults.standard
        let until = environment.now().addingTimeInterval(Self.laterInterval)
        defaults.set(release.version, forKey: Keys.laterVersion)
        defaults.set(until.timeIntervalSince1970, forKey: Keys.laterUntil)
        // Once the 24 hours are over, the offer is made noticeable again.
        if defaults.string(forKey: Keys.shownVersion) == release.version { defaults.removeObject(forKey: Keys.shownVersion) }
        if freshOffer?.version == release.version { freshOffer = nil }
        if let job = auto, job.release.version == release.version {
            job.stopWaiting?()
            job.download?.cancel()
            auto = nil
        }
        Self.log("\(release.version) put off until \(Self.time(until))")
    }

    /// A moment for the log, in local time.
    nonisolated static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Moving into Applications

    /// Where the running copy lies as the user sees it: a translocated copy runs from a random read-only path.
    private lazy var origin = Self.origin(of: Bundle.main.bundleURL)
    /// The running copy is being moved into an Applications folder: the app restarts from there in a moment.
    private var relocating = false

    /// A copy started outside the Applications folders is copied into one of them and restarts from there; when a copy
    /// there is as new or newer, that copy is opened instead. True when the app is about to restart.
    private func settle(after handoff: Handoff?) -> Bool {
        let running = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let version = currentVersion
        let origin = origin
        let action = Self.launchAction(for: origin, version: version, bundleID: bundleID, name: Self.bundleName, folders: folders)
        switch action {
        case .stay:
            return false
        case _ where handoff?.isRecent() == true:
            // Put here a moment ago and still not settled (translocated again, say): better to stay than to go in circles.
            Self.log("Started from \(origin.url.path) just after the move and would move again (\(action)): staying")
            return false
        case .open(let installed):
            Self.log("Started from \(origin.described), as new as \(installed.path) or older: switching to that copy")
            relocating = true
            // After the launch has finished: quitting earlier can go wrong.
            Task { await self.switchTo(installed) }
        case .move(let targets):
            Self.log("Started from \(origin.described): moving into \(targets[0].deletingLastPathComponent().path)"
                     + Self.passedOver(before: targets[0], bundleID: bundleID, folders: folders))
            relocating = true
            Task { await self.move(to: targets, from: running, bundleID: bundleID, version: version) }
        }
        return true
    }

    /// Hands over to the installed copy: brought to the front as it is when it runs already (no reopen: it shows no
    /// window it would show when started again), opened after this copy quits when it does not. Other running copies
    /// are asked to quit first; when one stays open, this copy just closes, so that two copies never run side by side.
    private func switchTo(_ installed: URL) async {
        let others = Self.otherCopies()
        let runningInstalled = others.first { $0.bundleURL.map { Self.same($0, installed) } ?? false }
        let stayed = await Self.askToQuit(others.filter { $0 != runningInstalled })
        if let runningInstalled {
            Self.log("\(installed.path) runs already: bringing it to the front")
            Self.bringToFront(runningInstalled)
            restart(Restart(version: nil, app: installed, leaving: origin, open: false), release: nil)
        } else if let other = stayed.first {
            close(nextTo: other)
        } else {
            restart(Restart(version: nil, app: installed, leaving: origin), release: nil)
        }
    }

    /// Moves into the first of `targets` that works and restarts from there. The other running copies, wherever they
    /// run from, are asked to quit first: nothing is replaced under a running process and no second copy starts next to
    /// one. When one stays open (busy, or the user said so), nothing is moved and this copy closes.
    private func move(to targets: [URL], from running: URL, bundleID: String, version: String) async {
        if let other = await Self.askToQuit(Self.otherCopies()).first {
            close(nextTo: other)
            return
        }
        let origin = origin
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.placeCopy(of: running, at: targets, inUse: [running, origin.url], bundleID: bundleID, version: version)
        }.value
        switch outcome {
        case .placed(let target), .found(let target):
            restart(Restart(version: nil, app: target, leaving: origin), release: nil)
        case .staged(let staged):
            restart(Restart(version: nil, app: staged.target, staged: staged, leaving: origin), release: nil)
        case .failed:
            stopRelocating()
        }
    }

    /// Another copy stayed open: this copy closes and leaves everything as it is, with the copy that stayed in front.
    /// Started again later, it tries again.
    private func close(nextTo other: NSRunningApplication) {
        Self.log("\(other.bundleURL?.path ?? "Another copy") stayed open: nothing is moved, this copy closes")
        Self.bringToFront(other)
        quit.request { [weak self] in self?.stopRelocating() }
    }

    /// The move did not happen, or the app stayed (the log says why): this copy goes on where it is.
    private func stopRelocating() {
        relocating = false
        scheduleChecks()
    }

    // MARK: - Restarting

    /// What the next quit does after an update or a move.
    private struct Restart {
        /// The version it brings, so that "Update" pressed again after a refused quit asks only for the quit; nil for a move.
        let version: String?
        /// Opened after the quit.
        let app: URL
        /// Swapped in for the running copy at the quit, so that the app never goes on working on a replaced bundle.
        var staged: Staged?
        /// The running copy, left behind for `app`.
        var leaving: Origin?
        /// Open `app` after the quit: the updater asked for the quit. A quit the user makes later only finishes the job, and
        /// an installed copy that runs already is brought to the front instead.
        var open = true
        /// Staged by an update that installs itself, or asked for by it rather than by "Update".
        var automatic = false
        /// Open `app` without bringing it to the front: the app was not in front when an automatic update restarted it.
        var background = false
        /// The app ran without a Dock icon (a windowed app started at login, a menu bar app): the new process starts the
        /// same way (`LoginItem.launchedAtLogin`).
        var quiet = false
    }

    private var pendingRestart: Restart?
    private lazy var quit: Quit = {
        let quit = Quit()
        quit.whenQuitting = { [weak self] in self?.quitting() }
        return quit
    }()

    /// Asks the app to quit, the way the user quits it, and to come back as `next.app`. A busy app may make the quit wait
    /// or refuse it (an export, a face scan, unsaved work): the running copy is untouched then, the offer comes back, and
    /// whatever quit comes next finishes the job without opening the app again.
    private func restart(_ next: Restart, release: Release?) {
        if let old = pendingRestart?.staged, old != next.staged { try? FileManager.default.removeItem(at: old.folder) }
        pendingRestart = next
        if let release {
            NotificationCenter.default.post(name: Self.willRestart, object: self,
                                            userInfo: ["release": release, "automatic": next.automatic])
        }
        quit.request { [weak self] in self?.refused(release) }
    }

    /// The app stayed: the next quit puts the new version in place. After "Update" the offer comes back; an update that
    /// installed itself tries the restart again with the next automatic check.
    private func refused(_ release: Release?) {
        guard pendingRestart?.open == true else { return }
        pendingRestart?.open = false
        Self.log("The app stayed instead of restarting; the next quit finishes the job")
        if relocating { stopRelocating() }
        guard let release, case .installing = state else { return }
        if pendingRestart?.automatic == true {
            auto?.parked = true
            auto?.finishing = false
            state = .idle
        } else {
            state = .available(release)
        }
    }

    /// The app is quitting (for the updater, for the user, for a logout): the staged copy goes in, the copy left behind
    /// goes to the Trash or its disk image is detached, and `app` opens when the updater asked for the quit.
    private func quitting() {
        guard let restart = pendingRestart else { return }
        pendingRestart = nil
        if let staged = restart.staged {
            if let other = Self.otherCopies().first(where: { $0.bundleURL.map { Self.same($0, staged.target) } ?? false }) {
                // Started there meanwhile: its bundle stays as it is.
                Self.log("\(staged.target.path) runs again (pid \(other.processIdentifier)): the new version stays out")
                try? FileManager.default.removeItem(at: staged.folder)
            } else if let failure = Self.swap(staged) {
                Self.log("The new version did not go in at the quit (\(failure)): \(staged.target.path) stays as it is")
            } else {
                Self.log("Put the new version at \(staged.target.path)")
            }
        }
        var image: URL?
        if let origin = restart.leaving {
            let moved = !Self.same(origin.url, restart.app)
            if moved { image = Self.diskImageMount(containing: origin.url) }
            // Back in the same place (a translocated copy put over its own original) the login item needs nothing.
            loginItem.refresh()
            Self.record(Handoff(from: origin.url, to: restart.app, loginItem: moved && loginItem.isEnabled))
            if moved && image == nil { Self.trash(origin.url, keeping: restart.app) }
        }
        var open = restart.open
        if open && Self.sessionIsEnding {
            Self.log("The Mac is logging out or shutting down: the app opens at its next launch")
            open = false
        }
        if open && restart.quiet { Self.recordQuietRelaunch(of: restart.app) }
        guard open || image != nil else { return }
        _ = scheduleRelaunch(open ? restart.app : nil, detaching: image, background: restart.background)
    }

    /// Opens `app` (when there is one, in the background when asked) once this process is gone, then detaches the disk
    /// image at `image`. False when that cannot be arranged.
    private func scheduleRelaunch(_ app: URL?, detaching image: URL? = nil, background: Bool = false) -> Bool {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = Self.relaunchArguments(pid: ProcessInfo.processInfo.processIdentifier, app: app, detaching: image,
                                                  background: background)
        waiter.standardInput = FileHandle.nullDevice
        waiter.standardOutput = FileHandle.nullDevice
        waiter.standardError = FileHandle.nullDevice
        do {
            try waiter.run()
            return true
        } catch {
            Self.log("Cannot arrange the restart from \(app?.path ?? "-"), it opens at its next launch: \(error.localizedDescription)")
            return false
        }
    }

    /// The app quits for the updater the way it quits for the user: through NSApp.terminate, so that its delegate can
    /// make the quit wait (`terminateLater`) or refuse it (busy, unsaved work).
    @MainActor final class Quit {
        /// Runs right before the process ends, whatever made the app quit.
        var whenQuitting: (() -> Void)?
        private var observer: NSObjectProtocol?

        init() {
            observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                              queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.whenQuitting?() }
            }
        }

        /// Asks the app to quit; `refused` runs once the app has decided to stay. While the app makes up its mind
        /// (`terminateLater`) AppKit keeps the run loop in the modal panel mode, and a quit that goes through never comes
        /// back to the default mode: a block for the default mode runs only after a refusal.
        func request(refused: @escaping () -> Void) {
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated { refused() }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
            NSApp.terminate(nil)
        }
    }

    /// The quit comes from a logout, a restart or a shutdown: opening the app again would get in its way.
    static var sessionIsEnding: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication) else { return false }
        let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) ?? event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        guard let why = reason?.enumCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown].map { OSType($0) }.contains(why)
    }

    // MARK: - Installing

    private var download: URLSessionDownloadTask?
    private var downloadID: UUID?
    /// The DMG kept after `cannotReplace`, for Finder.
    private var keptInstaller: URL?

    /// Where an update goes, best first: over the running copy when it can be replaced where it is, then into the
    /// Applications folders.
    private var installTargets: [URL] {
        let running = Bundle.main.bundleURL
        var targets = Self.inPlaceObstacle(running) == nil ? [running] : []
        for target in Self.targets(named: Self.bundleName, bundleID: Bundle.main.bundleIdentifier ?? "", in: folders)
        where !targets.contains(where: { Self.same($0, target) }) {
            targets.append(target)
        }
        return targets
    }

    private func startDownload(_ release: Release) {
        let id = UUID()
        downloadID = id
        download = fetch(release, progress: { [weak self] value in
            Task { @MainActor in self?.downloadProgressed(value, id: id) }
        }, finished: { [weak self] file in
            Task { @MainActor in self?.downloadFinished(file, id: id) }
        })
    }

    /// Downloads the DMG of `release` into the updates folder.
    private func fetch(_ release: Release, progress: @escaping @Sendable (Double) -> Void,
                       finished: @escaping @Sendable (URL?) -> Void) -> URLSessionDownloadTask {
        let folder = Self.updatesFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let receiver = DownloadReceiver(destination: folder.appendingPathComponent(release.dmg.lastPathComponent),
                                        expectedSize: release.size, progress: progress, finished: finished)
        var request = URLRequest(url: release.dmg)
        request.setValue("\(appName)/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let task = URLSession(configuration: .ephemeral, delegate: receiver, delegateQueue: nil).downloadTask(with: request)
        task.resume()
        return task
    }

    private func downloadProgressed(_ value: Double, id: UUID) {
        guard id == downloadID, case .downloading(let release, let shown) = state, value - shown >= 0.005 || value >= 1 else { return }
        state = .downloading(release, progress: value)
    }

    private func downloadFinished(_ file: URL?, id: UUID) {
        guard id == downloadID, case .downloading(let release, _) = state else {
            if let file { try? FileManager.default.removeItem(at: file) }
            return
        }
        downloadID = nil
        download = nil
        guard let file else {
            state = .failed(.download, release)
            return
        }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        guard release.size <= 0 || Int64(size) == release.size else {
            try? FileManager.default.removeItem(at: file)
            state = .failed(.damaged, release)
            return
        }
        // URLSession does not quarantine a download of an app that is not sandboxed; should that change, it shows here.
        // The installed copy never carries the quarantine either way (see `stage`).
        if Self.isQuarantined(file) { Self.log("\(file.lastPathComponent) arrived quarantined") }
        state = .installing(release)
        let running = Bundle.main.bundleURL
        let targets = installTargets
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        guard let first = targets.first else {
            Self.log("Cannot install \(release.version): \(origin.url.path) cannot be replaced (\(Self.inPlaceObstacle(running) ?? "?")) "
                     + "and no Applications folder can take it\(Self.passedOver(before: nil, bundleID: bundleID, folders: folders)); "
                     + "the installer is kept for Finder")
            keptInstaller = file
            state = .failed(.cannotReplace, release)
            return
        }
        if !Self.same(first, running) {
            Self.log("\(origin.url.path) cannot be replaced where it is (\(Self.inPlaceObstacle(running) ?? "?")): "
                     + "installing \(release.version) into \(first.deletingLastPathComponent().path)"
                     + Self.passedOver(before: first, bundleID: bundleID, folders: folders))
        }
        let current = currentVersion
        let origin = origin
        Task {
            // Nothing is replaced under another running copy, and the new version never starts next to one.
            if await Self.askToQuit(Self.otherCopies()).first != nil {
                Self.log("Another copy stayed open: \(release.version) waits until Update is pressed again")
                try? FileManager.default.removeItem(at: file)
                state = .available(release)
                return
            }
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.install(from: file, into: targets, inUse: [running, origin.url], bundleID: bundleID, newerThan: current)
            }.value
            switch outcome {
            case .placed(let target), .found(let target):
                try? FileManager.default.removeItem(at: file)
                restart(Restart(version: release.version, app: target, leaving: origin), release: release)
            case .staged(let staged):
                try? FileManager.default.removeItem(at: file)
                let inPlace = Self.same(staged.target, running)
                restart(Restart(version: release.version, app: staged.target, staged: staged, leaving: inPlace ? nil : origin),
                        release: release)
            case .failed(let failure):
                if failure == .cannotReplace {
                    Self.log("Could not put \(release.version) in place anywhere: the installer is kept for Finder")
                    keptInstaller = file
                } else {
                    try? FileManager.default.removeItem(at: file)
                }
                state = .failed(failure, release)
            }
        }
    }

    /// The new version waits in place: the other copies are asked to quit, then the app restarts as the new version.
    private func finish(_ next: Restart, release: Release, automatic: Bool) async {
        let stayed = await Self.askToQuit(Self.otherCopies())
        // Dropped meanwhile.
        guard pendingRestart?.version == release.version else {
            if !automatic, case .installing = state { state = .available(release) }
            return
        }
        if automatic {
            guard auto?.release.version == release.version else { return }
            auto?.finishing = false
            if !stayed.isEmpty {
                Self.log("Another copy stayed open: \(release.version) waits for the next automatic check")
                auto?.parked = true
                return
            }
            // Asking the other copies takes a while: the app may have got busy meanwhile.
            if restartObstacle() != nil { return tryRestart() }
        } else if !stayed.isEmpty {
            Self.log("Another copy stayed open: \(release.version) waits until Update is pressed again")
            state = .available(release)
            return
        }
        var next = next
        next.open = true
        next.automatic = automatic
        if automatic, let app = NSApp {
            next.background = !app.isActive
            next.quiet = app.activationPolicy() != .regular
            Self.log("Restarting as \(release.version)" + (next.quiet ? ", without a Dock icon" : "")
                     + (next.background ? ", in the background" : ""))
        }
        state = .installing(release)
        restart(next, release: release)
    }

    // MARK: - Installing by itself

    /// An update that installs itself (see `automaticInstall`).
    private struct AutomaticUpdate {
        let release: Release
        let id = UUID()
        var download: URLSessionDownloadTask?
        /// Checked and staged: `pendingRestart` holds it, and whatever quit comes first puts it in place.
        var ready = false
        /// The other copies are being asked to quit before the restart.
        var finishing = false
        /// The restart was refused or another copy stayed open: the next automatic check tries again.
        var parked = false
        /// Stops the wait until the app is free.
        var stopWaiting: (() -> Void)?
        /// The wait has gone to the log.
        var toldWaiting = false
    }

    private var auto: AutomaticUpdate? {
        willSet { objectWillChange.send() }
    }
    /// Failed attempts to install a version by itself, in this run.
    private var automaticFailures: [String: Int] = [:]

    /// Downloads, checks and stages `release` in the background, then restarts when the app is free; says what came of
    /// it, for the log.
    private func installAutomatically(_ release: Release) -> String {
        if let job = auto {
            if job.release.version == release.version {
                guard job.ready else { return "being downloaded already" }
                if job.parked {
                    auto?.parked = false
                    auto?.toldWaiting = false
                    tryRestart()
                }
                return "staged already, waiting for the restart"
            }
            dropAutomaticUpdate()
        }
        var job = AutomaticUpdate(release: release)
        if let next = pendingRestart, next.version == release.version, !next.open,
           FileManager.default.fileExists(atPath: next.staged?.copy.path ?? next.app.path) {
            // Staged before (a quit the app refused, "Later"): only the restart is left.
            job.ready = true
            auto = job
            pendingRestart?.automatic = true
            tryRestart()
            return "staged already, waiting for the restart"
        }
        let id = job.id
        auto = job
        auto?.download = fetch(release, progress: { _ in }, finished: { [weak self] file in
            Task { @MainActor in self?.automaticDownloadFinished(file, id: id) }
        })
        return "installing it by itself"
    }

    private func automaticDownloadFinished(_ file: URL?, id: UUID) {
        guard let job = auto, job.id == id else {
            if let file { try? FileManager.default.removeItem(at: file) }
            return
        }
        auto?.download = nil
        let release = job.release
        guard let file else { return automaticFailed(release, "the download broke off") }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        guard release.size <= 0 || Int64(size) == release.size else {
            try? FileManager.default.removeItem(at: file)
            return automaticFailed(release, "\(size) bytes downloaded instead of \(release.size)")
        }
        if Self.isQuarantined(file) { Self.log("\(file.lastPathComponent) arrived quarantined") }
        let running = Bundle.main.bundleURL
        let targets = installTargets
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let current = currentVersion
        let origin = origin
        Task {
            // Only staged, nothing replaced: the new version goes in when the app quits, for the restart or for the user,
            // and nothing is touched under another running copy before it has been asked to quit.
            let outcome = await Task.detached(priority: .utility) {
                Self.install(from: file, into: targets, inUse: targets + [running, origin.url], bundleID: bundleID, newerThan: current)
            }.value
            try? FileManager.default.removeItem(at: file)
            guard auto?.id == id else {
                if case .staged(let staged) = outcome { try? FileManager.default.removeItem(at: staged.folder) }
                return
            }
            guard case .staged(let staged) = outcome else {
                if case .failed(let failure) = outcome { return automaticFailed(release, "\(failure)") }
                return automaticFailed(release, "\(outcome)")
            }
            if let old = pendingRestart?.staged, old != staged { try? FileManager.default.removeItem(at: old.folder) }
            pendingRestart = Restart(version: release.version, app: staged.target, staged: staged,
                                     leaving: Self.same(staged.target, running) ? nil : origin, open: false, automatic: true)
            // Whatever quit comes first puts it in place: the quit is watched from now on.
            _ = quit
            auto?.ready = true
            Self.log("\(release.version) is ready: it goes in at the restart or the next quit")
            tryRestart()
        }
    }

    /// The staged update restarts the app as soon as nothing stands in the way, and asks again every minute until then.
    private func tryRestart() {
        guard let job = auto, job.ready, !job.parked, !job.finishing else { return }
        job.stopWaiting?()
        auto?.stopWaiting = nil
        guard let next = pendingRestart, next.version == job.release.version else {
            return automaticFailed(job.release, "the staged copy is gone")
        }
        if let obstacle = restartObstacle() {
            if !job.toldWaiting {
                Self.log("\(job.release.version) waits for the restart: \(obstacle)")
                auto?.toldWaiting = true
            }
            auto?.stopWaiting = environment.timer(environment.now().addingTimeInterval(Self.busyInterval)) { [weak self] in
                self?.tryRestart()
            }
            return
        }
        auto?.finishing = true
        Task { await self.finish(next, release: job.release, automatic: true) }
    }

    /// What keeps the app from restarting right now; nil when nothing does.
    private func restartObstacle() -> String? {
        switch state {
        case .checking, .downloading, .installing: return "the user is updating"
        default: break
        }
        if relocating { return "the app is moving" }
        if appIsBusy() { return "the app is busy" }
        if let mode = RunLoop.main.currentMode, mode != .default { return "a menu or a dialog is open" }
        if let app = NSApp, app.modalWindow != nil || app.windows.contains(where: { $0.attachedSheet != nil }) {
            return "a dialog is open"
        }
        return nil
    }

    /// Quietly: the log says why, and the next automatic check tries again; after the second failure with the same
    /// version it is offered.
    private func automaticFailed(_ release: Release, _ reason: String) {
        dropAutomaticUpdate()
        let failures = automaticFailures[release.version, default: 0] + 1
        automaticFailures[release.version] = failures
        guard failures >= Self.automaticAttempts else {
            Self.log("Could not install \(release.version) by itself (\(reason)): the next check tries again")
            return
        }
        Self.log("Could not install \(release.version) by itself (\(reason)): it is offered instead")
        switch state {
        case .idle, .upToDate, .available:
            state = .available(release)
            signal(release)
        default:
            break
        }
    }

    /// Stops an update that installs itself and removes what it has staged; `all`: also a copy it staged before and
    /// kept for the next quit ("Later").
    private func dropAutomaticUpdate(all: Bool = false) {
        let version = auto?.release.version
        if let job = auto {
            auto = nil
            job.download?.cancel()
            job.stopWaiting?()
        }
        guard let next = pendingRestart, next.automatic, !next.open, all || (version != nil && next.version == version) else { return }
        if let staged = next.staged { try? FileManager.default.removeItem(at: staged.folder) }
        pendingRestart = nil
    }

    /// What became of an update or a move.
    enum Installed: Equatable {
        /// The new copy is at this place now.
        case placed(URL)
        /// The new copy waits next to the running copy it replaces, and goes in when the app quits.
        case staged(Staged)
        /// The copy at this place is as new or newer: it is kept and started as it is.
        case found(URL)
        case failed(Failure)
    }

    /// Takes the app out of the DMG and puts it at the first of `targets` that works: over the running copy (`inUse`: it
    /// is staged then, see `Installed.staged`), or into an Applications folder. A copy in an Applications folder that is
    /// not older than the one in the DMG stays as it is.
    nonisolated static func install(from dmg: URL, into targets: [URL], inUse: [URL], bundleID: String, newerThan current: String,
                                    requirement: SecRequirement? = designatedRequirementOfSelf()) -> Installed {
        let files = FileManager.default
        let mount = files.temporaryDirectory.appendingPathComponent("Updater-\(UUID().uuidString)", isDirectory: true)
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path]) else {
            try? files.removeItem(at: mount)
            log("Cannot open \(dmg.lastPathComponent)")
            return .failed(.damaged)
        }
        defer {
            if !run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) {
                _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
            }
            try? files.removeItem(at: mount)
        }

        let apps = ((try? files.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
        guard let app = apps.first(where: { info($0)?["CFBundleIdentifier"] as? String == bundleID })
                ?? apps.first(where: { $0.lastPathComponent == targets.first?.lastPathComponent }) ?? apps.first else {
            log("No app in \(dmg.lastPathComponent)")
            return .failed(.damaged)
        }
        guard let requirement else {
            log("The running copy has no designated requirement to check the new version against")
            return .failed(.notTrusted)
        }
        let offered = info(app)?["CFBundleShortVersionString"] as? String ?? ""
        return put(app, at: targets, inUse: inUse, bundleID: bundleID, newerThan: current, orSame: false, requirement: requirement) {
            guard let installed = info($0), installed["CFBundleIdentifier"] as? String == bundleID,
                  let version = installed["CFBundleShortVersionString"] as? String, compare(version, offered) != .orderedAscending else {
                return false
            }
            log("\($0.path) has \(version) already")
            return true
        }
    }

    /// The app is the same app, newer (or, with `orSame`, as new), and its signature satisfies `requirement` (for every
    /// architecture, strictly, nested code included).
    nonisolated static func verify(_ app: URL, bundleID: String, newerThan current: String, orSame: Bool = false,
                                   requirement: SecRequirement) -> Failure? {
        guard let info = info(app) else { return .damaged }
        guard info["CFBundleIdentifier"] as? String == bundleID else { return .notTrusted }
        guard let version = info["CFBundleShortVersionString"] as? String else { return .damaged }
        let order = compare(version, current)
        guard order == .orderedDescending || (orSame && order == .orderedSame) else { return .damaged }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return .notTrusted }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode))
        guard SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess else { return .notTrusted }
        return nil
    }

    /// What the running copy's signature requires of itself: the same identifier and certificate. For a copy signed
    /// ad hoc that is its exact code, so nothing else satisfies it.
    nonisolated static func designatedRequirementOfSelf() -> SecRequirement? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    // MARK: - Helpers

    /// What the answer of `GET /repos/{repo}/releases/latest` means for a copy of `appName` at version `current`;
    /// nil when it cannot be read. The installer is `<appName>-<version>.dmg`, or else any DMG of the release.
    nonisolated static func latest(from data: Data, appName: String, current: String) -> Latest? {
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else { return nil }
        var version = release.tag
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        guard compare(version, current) == .orderedDescending else { return .nothingNewer }
        let installer = release.assets.first { $0.name == "\(appName)-\(version).dmg" }
            ?? release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        guard let installer else { return .noInstaller(page: release.page) }
        let title = release.name.flatMap { $0.isEmpty ? nil : $0 } ?? release.tag
        let notes = (release.body ?? "").replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return .newer(Release(version: version, title: title, notes: notes, page: release.page, dmg: installer.url, size: installer.size))
    }

    /// Compares versions by their numbers: 2.10 is newer than 2.9, 2.0 equals 2.0.0, "v" in front and a suffix after
    /// "-" or "+" do not count.
    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = numbers(a), y = numbers(b)
        for index in 0..<max(x.count, y.count) {
            let p = index < x.count ? x[index] : 0, q = index < y.count ? y[index] : 0
            if p != q { return p < q ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private nonisolated static func numbers(_ version: String) -> [Int] {
        var text = Substring(version.trimmingCharacters(in: .whitespaces))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        return text.prefix { $0 != "-" && $0 != "+" }.split(separator: ".").map { part in
            Int(part.prefix { $0.isASCII && $0.isNumber }) ?? 0
        }
    }

    /// Not an app bundle, or inside the build/ folder (build/dmg/ too) next to Package.swift.
    nonisolated static func isDevelopmentBuild(_ bundle: URL) -> Bool {
        guard bundle.pathExtension == "app" else { return true }
        let folders = Array(bundle.standardizedFileURL.pathComponents.dropLast())
        return folders.indices.contains { index in
            folders[index] == "build"
                && FileManager.default.fileExists(atPath: NSString.path(withComponents: Array(folders[..<index]) + ["Package.swift"]))
        }
    }

    /// Why the copy cannot be replaced where it is, for the log; nil when it can.
    nonisolated static func inPlaceObstacle(_ bundle: URL) -> String? {
        // A translocated copy runs from a random read-only path; the app stays where it was downloaded.
        if isTranslocated(bundle) { return "translocated" }
        if (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return "read-only volume" }
        let files = FileManager.default
        if !files.isWritableFile(atPath: bundle.deletingLastPathComponent().path) { return "its folder is not writable" }
        if !files.isWritableFile(atPath: bundle.path) { return "it is not writable" }
        return nil
    }

    /// ~/Library/Caches/<bundle id>/Updates
    nonisolated static var updatesFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Updater", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }

    nonisolated static func info(_ app: URL) -> [String: Any]? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int64
            let url: URL
            enum CodingKeys: String, CodingKey { case name, size, url = "browser_download_url" }
        }

        let tag: String
        let name: String?
        let body: String?
        let page: URL
        let assets: [Asset]
        enum CodingKeys: String, CodingKey { case tag = "tag_name", name, body, page = "html_url", assets }
    }

    /// Receives the DMG with progress and moves it to `destination` before URLSession deletes it.
    private final class DownloadReceiver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let expectedSize: Int64
        let progress: @Sendable (Double) -> Void
        let finished: @Sendable (URL?) -> Void
        /// Touched only on the session's serial delegate queue.
        private var file: URL?

        init(destination: URL, expectedSize: Int64, progress: @escaping @Sendable (Double) -> Void,
             finished: @escaping @Sendable (URL?) -> Void) {
            self.destination = destination
            self.expectedSize = expectedSize
            self.progress = progress
            self.finished = finished
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
            guard total > 0 else { return }
            progress(min(1, Double(totalBytesWritten) / Double(total)))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return }
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.moveItem(at: location, to: destination)) != nil { file = destination }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            finished(error == nil ? file : nil)
            session.finishTasksAndInvalidate()
        }
    }
}
