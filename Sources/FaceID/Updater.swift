import AppKit
import Foundation
import Security
import ServiceManagement

/// Updates the app from its releases on GitHub: finds a newer release, downloads its DMG, checks that the app inside
/// is signed by the same certificate as the running copy, puts it in place and relaunches. The app lives in
/// /Applications, or in ~/Applications when this user may not write to /Applications: a copy started anywhere else (an
/// open DMG, a translocated copy, Downloads) moves itself there at launch, and an update that cannot replace the running
/// copy goes there as well (see Updater+Placement.swift). None of it asks anything; the reasons of every detour go to
/// the app's log. Every app of the family carries this very file and Updater+Placement.swift, byte for byte: they have
/// no interface texts and know nothing about the app, which shows the states in its own words and style.
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

    init(repo: String, apiBase: URL = URL(string: "https://api.github.com")!) {
        self.repo = repo
        self.apiBase = apiBase
    }

    @Published private(set) var state: State = .idle

    /// Automatic checks; on by default.
    var automaticChecks: Bool {
        get { UserDefaults.standard.object(forKey: Keys.automaticChecks) as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Keys.automaticChecks)
            scheduleChecks()
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// A copy built from the sources (in build/ next to Package.swift, or not an app bundle at all): it never checks by
    /// itself, never moves and never replaces itself.
    var isDevelopmentBuild: Bool { Self.isDevelopmentBuild(Bundle.main.bundleURL) }

    /// An update installs itself: over the running copy, or into an Applications folder when the running copy cannot be
    /// replaced where it is (translocated, on a read-only volume, in a folder this user may not write to). False for a
    /// development build, and when no Applications folder can be written either.
    var installsByItself: Bool { !isDevelopmentBuild && !installTargets.isEmpty }

    /// The former name of `installsByItself`, from when an update could only replace the running copy.
    var canInstallInPlace: Bool { installsByItself }

    /// Starts the automatic checks: about 10 s after launch, then every 24 hours. Before that a copy that has just taken
    /// over from another one finishes the handoff, and a copy started outside the Applications folders moves there (or
    /// switches to the copy installed there) and restarts, with no checks meanwhile. `folders` are where the app is
    /// installed, best first: the apps leave them as they are, the test harness gives its own.
    func start(applicationFolders folders: [URL] = Updater.applicationFolders) {
        guard !started else { return }
        started = true
        self.folders = folders
        try? FileManager.default.removeItem(at: Self.updatesFolder)
        if !isDevelopmentBuild {
            let handoff = Self.takeHandoff(to: origin.url)
            if let handoff { Self.finish(handoff) }
            if settle(after: handoff) { return }
        }
        scheduleChecks()
    }

    /// Asks GitHub for the latest release. `upToDate` and failures are shown only after a check the user asked for;
    /// an automatic check stays silent and does not offer a skipped version.
    func check(userInitiated: Bool) {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        guard !relocating, userInitiated || (automaticChecks && !isDevelopmentBuild) else { return }
        if userInitiated { state = .checking }
        Task { [weak self] in
            guard let self else { return }
            let answer = await self.askGitHub()
            self.apply(answer, userInitiated: userInitiated)
        }
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
        // In place already and waiting for a quit the app refused: only the quit is asked for again.
        if var next = pendingRestart, next.version == release.version,
           FileManager.default.fileExists(atPath: next.staged?.copy.path ?? next.app.path) {
            next.open = true
            state = .installing(release)
            restart(next, release: release)
            return
        }
        keptInstaller = nil
        state = .downloading(release, progress: 0)
        startDownload(release)
    }

    /// Never offers this version by itself again (a check the user asks for still shows it).
    func skip() {
        switch state {
        case .available(let release), .failed(_, let release?):
            UserDefaults.standard.set(release.version, forKey: Keys.skippedVersion)
            if pendingRestart?.version == release.version {
                if let staged = pendingRestart?.staged { try? FileManager.default.removeItem(at: staged.folder) }
                pendingRestart = nil
            }
            state = .idle
        default: break
        }
    }

    /// "Later": the offer comes back with the next automatic check.
    func dismiss() {
        switch state {
        case .available, .upToDate, .failed: state = .idle
        default: break
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

    private let repo: String
    private let apiBase: URL
    private var started = false
    /// Where the app is installed, best first (see `start`).
    private var folders = Updater.applicationFolders
    private var firstCheck: Task<Void, Never>?
    private var timer: Timer?
    /// The page of the latest release seen, for a failure that has no release to show.
    private var latestPage: URL?

    private enum Keys {
        static let automaticChecks = "checkForUpdates"
        static let skippedVersion = "skippedUpdateVersion"
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

    private func scheduleChecks() {
        firstCheck?.cancel()
        firstCheck = nil
        timer?.invalidate()
        timer = nil
        guard started, !relocating, automaticChecks, !isDevelopmentBuild else { return }
        firstCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.check(userInitiated: false)
        }
        // A timer keeps wall-clock time: after the Mac sleeps through it, it fires on wake.
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(userInitiated: false) }
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
        case latest(Latest)
        case failed(Failure)
    }

    private func askGitHub() async -> Answer {
        var request = URLRequest(url: apiBase.appendingPathComponent("repos/\(repo)/releases/latest"), timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(appName)/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request) else { return .failed(.offline) }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            guard let latest = Self.latest(from: data, appName: appName, current: currentVersion) else { return .failed(.offline) }
            return .latest(latest)
        case 404:
            return .latest(.nothingNewer)
        case 403, 429:
            return .failed(.rateLimited)
        default:
            return .failed(.offline)
        }
    }

    /// An automatic answer changes only an offer; whatever the user is looking at (a check, a download, an error) stays.
    private func apply(_ answer: Answer, userInitiated: Bool) {
        switch state {
        case .downloading, .installing: return
        case .checking where !userInitiated: return
        default: break
        }
        var offered = false
        if case .available = state { offered = true }
        switch answer {
        case .latest(.newer(let release)):
            latestPage = release.page
            if userInitiated || release.version != UserDefaults.standard.string(forKey: Keys.skippedVersion) {
                state = .available(release)
            } else if offered {
                state = .idle
            }
        case .latest(.noInstaller(let page)):
            latestPage = page
            if userInitiated {
                state = .failed(.noInstaller, nil)
            } else if offered {
                state = .idle
            }
        case .latest(.nothingNewer):
            if userInitiated {
                state = .upToDate
            } else if offered {
                state = .idle
            }
        case .failed(let failure):
            if userInitiated { state = .failed(failure, nil) }
        }
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
        quit.request { [weak self] in self?.refused(release) }
    }

    /// The app stayed: the next quit puts the new version in place.
    private func refused(_ release: Release?) {
        guard pendingRestart?.open == true else { return }
        pendingRestart?.open = false
        Self.log("The app stayed instead of restarting; the next quit finishes the job")
        if relocating { stopRelocating() }
        if let release, case .installing = state { state = .available(release) }
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
            Self.record(Handoff(from: origin.url, to: restart.app, loginItem: moved && SMAppService.mainApp.status == .enabled))
            if moved && image == nil { Self.trash(origin.url, keeping: restart.app) }
        }
        var open = restart.open
        if open && Self.sessionIsEnding {
            Self.log("The Mac is logging out or shutting down: the app opens at its next launch")
            open = false
        }
        guard open || image != nil else { return }
        _ = scheduleRelaunch(open ? restart.app : nil, detaching: image)
    }

    /// Opens `app` (when there is one) once this process is gone, then detaches the disk image at `image`. False when that
    /// cannot be arranged.
    private func scheduleRelaunch(_ app: URL?, detaching image: URL? = nil) -> Bool {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = Self.relaunchArguments(pid: ProcessInfo.processInfo.processIdentifier, app: app, detaching: image)
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
        let folder = Self.updatesFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let receiver = DownloadReceiver(
            destination: folder.appendingPathComponent(release.dmg.lastPathComponent),
            expectedSize: release.size,
            progress: { [weak self] value in
                Task { @MainActor in self?.downloadProgressed(value, id: id) }
            },
            finished: { [weak self] file in
                Task { @MainActor in self?.downloadFinished(file, id: id) }
            })
        var request = URLRequest(url: release.dmg)
        request.setValue("\(appName)/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let task = URLSession(configuration: .ephemeral, delegate: receiver, delegateQueue: nil).downloadTask(with: request)
        download = task
        task.resume()
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
