import AppKit
import Foundation
import Security

/// Updates the app from its releases on GitHub: finds a newer release, downloads its DMG, checks that the app inside
/// is signed by the same certificate as the running copy, puts it in place of the running copy and relaunches.
/// Every app of the family carries this very file, byte for byte: it has no interface texts and knows nothing about
/// the app, which shows the states in its own words and style.
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

    enum Failure: Equatable {
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
        /// The running copy cannot be replaced (App Translocation, read-only volume, no write access): the
        /// downloaded DMG can be opened in Finder instead, see `openReleasePage()`.
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
    /// itself and never replaces itself.
    var isDevelopmentBuild: Bool { Self.isDevelopmentBuild(Bundle.main.bundleURL) }

    /// The running copy can be replaced: it is not translocated by Gatekeeper, not on a read-only volume (an open DMG)
    /// and its folder can be written.
    var canInstallInPlace: Bool { Self.canInstall(at: Bundle.main.bundleURL) }

    /// Starts the automatic checks: about 10 s after launch, then every 24 hours.
    func start() {
        guard !started else { return }
        started = true
        try? FileManager.default.removeItem(at: Self.updatesFolder)
        scheduleChecks()
    }

    /// Asks GitHub for the latest release. `upToDate` and failures are shown only after a check the user asked for;
    /// an automatic check stays silent and does not offer a skipped version.
    func check(userInitiated: Bool) {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        guard userInitiated || (automaticChecks && !isDevelopmentBuild) else { return }
        if userInitiated { state = .checking }
        Task { [weak self] in
            guard let self else { return }
            let answer = await self.askGitHub()
            self.apply(answer, userInitiated: userInitiated)
        }
    }

    /// Downloads the offered release, checks it, replaces the running copy and relaunches it.
    func install() {
        let release: Release
        switch state {
        case .available(let offered): release = offered
        case .failed(_, let offered?): release = offered
        default: return
        }
        guard !isDevelopmentBuild else {
            state = .failed(.cannotReplace, release)
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
    private var firstCheck: Task<Void, Never>?
    private var timer: Timer?
    /// The page of the latest release seen, for a failure that has no release to show.
    private var latestPage: URL?

    private enum Keys {
        static let automaticChecks = "checkForUpdates"
        static let skippedVersion = "skippedUpdateVersion"
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
    }

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
        guard started, automaticChecks, !isDevelopmentBuild else { return }
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

    // MARK: - Installing

    private var download: URLSessionDownloadTask?
    private var downloadID: UUID?
    /// The DMG kept after `cannotReplace`, for Finder.
    private var keptInstaller: URL?

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
        state = .installing(release)
        guard canInstallInPlace else {
            keptInstaller = file
            state = .failed(.cannotReplace, release)
            return
        }
        let target = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let current = currentVersion
        Task {
            let failure = await Task.detached(priority: .userInitiated) {
                Self.replace(target, withAppFrom: file, bundleID: bundleID, newerThan: current)
            }.value
            if failure == .cannotReplace {
                keptInstaller = file
            } else {
                try? FileManager.default.removeItem(at: file)
            }
            if let failure {
                state = .failed(failure, release)
            } else {
                relaunch()
            }
        }
    }

    /// Waits until this process is gone, then opens the new copy, and quits.
    private func relaunch() {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$1\"",
                            String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        waiter.standardInput = FileHandle.nullDevice
        waiter.standardOutput = FileHandle.nullDevice
        waiter.standardError = FileHandle.nullDevice
        do {
            try waiter.run()
        } catch {
            // The new version is in place already and starts next time.
            state = .idle
            return
        }
        NSApp.terminate(nil)
    }

    /// Takes the app out of the DMG into a folder on the same volume as `target`, checks it and swaps it with `target`.
    nonisolated static func replace(_ target: URL, withAppFrom dmg: URL, bundleID: String, newerThan current: String) -> Failure? {
        let files = FileManager.default
        let mount = files.temporaryDirectory.appendingPathComponent("Updater-\(UUID().uuidString)", isDirectory: true)
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path]) else {
            try? files.removeItem(at: mount)
            return .damaged
        }
        var mounted = true
        func detach() {
            guard mounted else { return }
            mounted = false
            if !run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) {
                _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
            }
            try? files.removeItem(at: mount)
        }
        defer { detach() }

        let apps = ((try? files.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
        guard let app = apps.first(where: { $0.lastPathComponent == target.lastPathComponent })
                ?? apps.first(where: { info($0)?["CFBundleIdentifier"] as? String == bundleID }) ?? apps.first else { return .damaged }
        guard let staging = try? files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true) else {
            return .cannotReplace
        }
        defer { try? files.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(target.lastPathComponent, isDirectory: true)
        guard run("/usr/bin/ditto", ["--noqtn", app.path, staged.path]) else { return .damaged }
        detach()

        guard let requirement = designatedRequirementOfSelf() else { return .notTrusted }
        if let failure = verify(staged, bundleID: bundleID, newerThan: current, requirement: requirement) { return failure }
        do {
            _ = try files.replaceItemAt(target, withItemAt: staged)
        } catch {
            return .cannotReplace
        }
        return nil
    }

    /// The app is the same app, newer, and its signature satisfies `requirement` (for every architecture, strictly,
    /// nested code included).
    nonisolated static func verify(_ app: URL, bundleID: String, newerThan current: String, requirement: SecRequirement) -> Failure? {
        guard let info = info(app) else { return .damaged }
        guard info["CFBundleIdentifier"] as? String == bundleID else { return .notTrusted }
        guard let version = info["CFBundleShortVersionString"] as? String, compare(version, current) == .orderedDescending else {
            return .damaged
        }
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

    nonisolated static func isDevelopmentBuild(_ bundle: URL) -> Bool {
        guard bundle.pathExtension == "app" else { return true }
        let folder = bundle.deletingLastPathComponent()
        return folder.lastPathComponent == "build"
            && FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("Package.swift").path)
    }

    nonisolated static func canInstall(at bundle: URL) -> Bool {
        // A translocated copy runs from a random read-only path; the app stays where it was downloaded.
        guard !bundle.path.contains("/AppTranslocation/") else { return false }
        if (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return false }
        let files = FileManager.default
        return files.isWritableFile(atPath: bundle.deletingLastPathComponent().path) && files.isWritableFile(atPath: bundle.path)
    }

    /// ~/Library/Caches/<bundle id>/Updates
    nonisolated static var updatesFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Updater", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }

    private nonisolated static func info(_ app: URL) -> [String: Any]? {
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
