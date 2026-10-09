import AppKit
import Foundation
import os
import Security
import ServiceManagement

/// Where the copies of the app lie and how a copy gets into place. The app lives in /Applications, or in ~/Applications
/// when this user may not write to /Applications; a copy anywhere else moves there by itself (see `Updater.start()`).
/// Part of `Updater`, carried byte for byte by every app of the family like Updater.swift.
extension Updater {
    // MARK: Where a copy lies

    /// Where a copy lies as the user sees it.
    struct Origin: Equatable {
        /// The bundle; for a translocated copy, the place it was started from (or, when the system does not tell, the
        /// random path it runs from).
        let url: URL
        /// Started from a quarantined place (Downloads, a DMG), the copy runs from a random read-only path.
        let translocated: Bool

        /// The path for the log.
        var described: String { translocated ? "\(url.path) (translocated)" : url.path }
    }

    nonisolated static func origin(of running: URL) -> Origin {
        guard isTranslocated(running) else { return Origin(url: running, translocated: false) }
        return Origin(url: translocationOriginal(of: running) ?? running, translocated: true)
    }

    /// Where a copy lies, as far as moving goes.
    enum Place: Equatable {
        /// Built from the sources: stays where it is.
        case development
        /// In /Applications or ~/Applications, at any depth.
        case installed
        /// Anywhere else: an open disk image, a translocated copy, Downloads, the desktop, another disk.
        case elsewhere
    }

    nonisolated static func place(of bundle: URL, translocated: Bool, readOnly: Bool, folders: [URL]) -> Place {
        if isDevelopmentBuild(bundle) { return .development }
        if translocated || readOnly { return .elsewhere }
        let path = normalized(bundle)
        return folders.contains { path.hasPrefix(normalized($0) + "/") } ? .installed : .elsewhere
    }

    // MARK: What a copy does at launch

    struct InstalledCopy: Equatable {
        let url: URL
        let version: String
    }

    enum LaunchAction: Equatable {
        case stay
        /// Opens this copy in an Applications folder instead: it is as new or newer.
        case open(URL)
        /// Puts a copy of the running one at the first of these places that works and restarts from there.
        case move([URL])
    }

    /// What the copy at `origin` does at launch; the copies in the Applications folders are named `name`, `folders` go
    /// best first.
    nonisolated static func launchAction(for origin: Origin, version: String, bundleID: String, name: String,
                                         folders: [URL]) -> LaunchAction {
        let readOnly = (try? origin.url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
        let location = place(of: origin.url, translocated: origin.translocated, readOnly: readOnly, folders: folders)
        guard location != .development else { return .stay }
        let installed = folders.compactMap { folder -> InstalledCopy? in
            let url = folder.appendingPathComponent(name, isDirectory: true)
            guard !same(url, origin.url), let plist = info(url), plist["CFBundleIdentifier"] as? String == bundleID,
                  let version = plist["CFBundleShortVersionString"] as? String else { return nil }
            return InstalledCopy(url: url, version: version)
        }
        let candidates = location == .elsewhere ? targets(named: name, bundleID: bundleID, in: folders) : []
        return decide(location, version: version, installed: installed, targets: candidates)
    }

    /// A copy outside the Applications folders opens an installed copy that is as new or newer, or else moves. An
    /// installed copy gives way only to a newer one: two of the same version would hand over to each other forever.
    nonisolated static func decide(_ place: Place, version: String, installed: [InstalledCopy], targets: [URL]) -> LaunchAction {
        switch place {
        case .development:
            return .stay
        case .installed:
            let newer = installed.filter { compare($0.version, version) == .orderedDescending }
            return newest(newer).map { .open($0.url) } ?? .stay
        case .elsewhere:
            if let copy = newest(installed.filter({ compare($0.version, version) != .orderedAscending })) { return .open(copy.url) }
            return targets.isEmpty ? .stay : .move(targets)
        }
    }

    /// The newest copy; of equally new ones the first, the folders going best first.
    private nonisolated static func newest(_ copies: [InstalledCopy]) -> InstalledCopy? {
        copies.reduce(nil) { best, copy in
            guard let best else { return copy }
            return compare(copy.version, best.version) == .orderedDescending ? copy : best
        }
    }

    // MARK: Applications folders

    /// /Applications, then ~/Applications.
    nonisolated static var applicationFolders: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// The name of the app in an Applications folder, whatever the running copy is called ("Subline 2.app" in Downloads).
    nonisolated static var bundleName: String { "\(appName).app" }

    nonisolated static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
    }

    /// Where a copy named `name` can go, best first: into each of `folders` this user may write to (or make), unless the
    /// copy there is another app or cannot be replaced.
    nonisolated static func targets(named name: String, bundleID: String, in folders: [URL]) -> [URL] {
        folders.filter { obstacle(in: $0, named: name, bundleID: bundleID) == nil }.map { $0.appendingPathComponent(name, isDirectory: true) }
    }

    /// Why a copy named `name` cannot go into `folder`; nil when it can.
    nonisolated static func obstacle(in folder: URL, named name: String, bundleID: String) -> String? {
        let files = FileManager.default
        var isFolder: ObjCBool = false
        if files.fileExists(atPath: folder.path, isDirectory: &isFolder) {
            guard isFolder.boolValue else { return "not a folder" }
            guard files.isWritableFile(atPath: folder.path) else { return "this user may not write there" }
        } else if !files.isWritableFile(atPath: folder.deletingLastPathComponent().path) {
            return "missing, and this user may not make it"
        }
        let target = folder.appendingPathComponent(name, isDirectory: true)
        guard files.fileExists(atPath: target.path) else { return nil }
        guard info(target)?["CFBundleIdentifier"] as? String == bundleID else { return "\(name) there is another app" }
        return files.isWritableFile(atPath: target.path) ? nil : "this user may not replace \(name) there"
    }

    /// For the log: why the Applications folders before the one of `target` (all of them, when nil) were passed over.
    nonisolated static func passedOver(before target: URL?, bundleID: String, folders: [URL] = applicationFolders) -> String {
        let name = target?.lastPathComponent ?? bundleName
        let reasons = folders.prefix { folder in target.map { !same(folder, $0.deletingLastPathComponent()) } ?? true }.compactMap { folder in
            obstacle(in: folder, named: name, bundleID: bundleID).map { "\(folder.path): \($0)" }
        }
        return reasons.isEmpty ? "" : " (passed over \(reasons.joined(separator: "; ")))"
    }

    // MARK: Putting a copy in place

    /// Puts a copy of the running app at the first of `targets` that works (staged when the target is in use, see
    /// `put`); the log says why when none does.
    nonisolated static func placeCopy(of source: URL, at targets: [URL], inUse: [URL], bundleID: String, version: String,
                                      requirement: SecRequirement? = designatedRequirementOfSelf()) -> Installed {
        guard let requirement else {
            log("The running copy has no designated requirement to check its copy against")
            return .failed(.notTrusted)
        }
        return put(source, at: targets, inUse: inUse, bundleID: bundleID, newerThan: version, orSame: true, requirement: requirement)
    }

    /// Puts a copy of `source` at the first of `targets` that works. For a target in use (the running copy, or the place
    /// a translocated copy was started from) the copy is staged next to it and goes in when the app quits, so that the
    /// running app never works on a replaced bundle. A target `isEnough` accepts as it is stays as it is.
    nonisolated static func put(_ source: URL, at targets: [URL], inUse: [URL], bundleID: String, newerThan current: String,
                                orSame: Bool, requirement: SecRequirement, keep isEnough: (URL) -> Bool = { _ in false }) -> Installed {
        for target in targets {
            let busy = inUse.contains { same($0, target) }
            if !busy, isEnough(target) { return .found(target) }
            switch stage(source, for: target, bundleID: bundleID, newerThan: current, orSame: orSame, requirement: requirement) {
            case .failure(.cannotReplace):
                continue
            case .failure(let failure):
                // The copy itself is wrong: another folder would not make it right.
                return .failed(failure)
            case .success(let staged) where busy:
                log("Staged the new copy for \(target.path): it goes in when the app quits")
                return .staged(staged)
            case .success(let staged):
                switch swap(staged) {
                case nil:
                    log("Put the new copy at \(target.path)")
                    return .placed(target)
                case .cannotReplace?:
                    continue
                case let failure?:
                    return .failed(failure)
                }
            }
        }
        return .failed(.cannotReplace)
    }

    /// A checked copy of the app in a folder of its own on the volume of `target`, to be swapped in for it.
    struct Staged: Equatable {
        /// The folder; removed with whatever is left in it.
        let folder: URL
        let copy: URL
        let target: URL
    }

    /// Copies the app at `source` into a new folder on the volume of `target`, takes the quarantine off the copy (the user
    /// has started this app already, and a new version must pass `verify` against the running copy) and checks it. The
    /// app copies itself rather than through ditto: macOS lets an app read its own bundle where it guards the folder
    /// (Downloads, a disk image).
    nonisolated static func stage(_ source: URL, for target: URL, bundleID: String, newerThan current: String, orSame: Bool = false,
                                  requirement: SecRequirement) -> Result<Staged, Failure> {
        let files = FileManager.default
        let folder = target.deletingLastPathComponent()
        let staging: URL
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        } catch {
            log("Cannot prepare \(folder.path): \(error.localizedDescription)")
            return .failure(.cannotReplace)
        }
        let copy = staging.appendingPathComponent(target.lastPathComponent, isDirectory: true)
        do {
            try files.copyItem(at: source, to: copy)
        } catch {
            try? files.removeItem(at: staging)
            log("Cannot copy \(source.path) to the volume of \(folder.path): \(error.localizedDescription)")
            return .failure(.damaged)
        }
        removeQuarantine(copy)
        if let failure = verify(copy, bundleID: bundleID, newerThan: current, orSame: orSame, requirement: requirement) {
            try? files.removeItem(at: staging)
            log("The copy of \(source.path) fails the check (\(failure)), \(target.path) stays as it is")
            return .failure(failure)
        }
        return .success(Staged(folder: staging, copy: copy, target: target))
    }

    /// Swaps the staged copy in for its target, or moves it there when there is nothing yet; the staging folder goes.
    nonisolated static func swap(_ staged: Staged) -> Failure? {
        let files = FileManager.default
        defer { try? files.removeItem(at: staged.folder) }
        do {
            if files.fileExists(atPath: staged.target.path) {
                _ = try files.replaceItemAt(staged.target, withItemAt: staged.copy)
            } else {
                try files.moveItem(at: staged.copy, to: staged.target)
            }
        } catch {
            log("Cannot put the copy at \(staged.target.path): \(error.localizedDescription)")
            return .cannotReplace
        }
        return nil
    }

    // MARK: Quarantine

    private nonisolated static let quarantine = "com.apple.quarantine"

    nonisolated static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, quarantine, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Removes the quarantine from the bundle and everything in it, so that macOS does not ask again whether to open it.
    nonisolated static func removeQuarantine(_ bundle: URL) {
        func strip(_ path: String) {
            guard removexattr(path, quarantine, XATTR_NOFOLLOW) != 0, errno == EACCES else { return }
            // A file its owner may not write keeps its attributes too: opened up for a moment.
            var status = stat()
            guard lstat(path, &status) == 0, status.st_mode & S_IFMT != S_IFLNK, chmod(path, status.st_mode | S_IWUSR) == 0 else { return }
            removexattr(path, quarantine, XATTR_NOFOLLOW)
            chmod(path, status.st_mode & 0o7777)
        }
        strip(bundle.path)
        guard let items = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in items {
            strip(item.path)
        }
    }

    // MARK: App Translocation

    /// A copy started from a quarantined place runs from a random read-only path. The Security calls that tell are not
    /// public, but have been there since macOS 10.12; without them the path still gives it away.
    nonisolated static func isTranslocated(_ bundle: URL) -> Bool {
        var translocated = false
        if let check = Translocation.isTranslocated, check(bundle as CFURL, &translocated, nil) != 0 { return translocated }
        return bundle.path.contains("/AppTranslocation/")
    }

    /// The place a translocated copy was started from.
    nonisolated static func translocationOriginal(of bundle: URL) -> URL? {
        Translocation.originalPath?(bundle as CFURL, nil)?.takeRetainedValue() as URL?
    }

    private enum Translocation {
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> UInt8
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

        static let isTranslocated = symbol("SecTranslocateIsTranslocatedURL", as: IsTranslocated.self)
        static let originalPath = symbol("SecTranslocateCreateOriginalPathForURL", as: OriginalPath.self)

        private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
                  let address = dlsym(security, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
    }

    // MARK: Leaving a copy behind

    /// The mount point of the disk image `url` lies on; nil when it is not on one.
    nonisolated static func diskImageMount(containing url: URL) -> URL? {
        guard let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume, normalized(volume) != "/",
              let data = output("/usr/bin/hdiutil", ["info", "-plist"]),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        let mountPoints = (plist["images"] as? [[String: Any]] ?? [])
            .flatMap { $0["system-entities"] as? [[String: Any]] ?? [] }
            .compactMap { $0["mount-point"] as? String }
        return mountPoints.contains { same(URL(fileURLWithPath: $0), volume) } ? volume : nil
    }

    /// Puts the copy at `old`, the running one, into the Trash after the app has moved to `kept`; the process goes on
    /// until it quits.
    nonisolated static func trash(_ old: URL, keeping kept: URL) {
        if let reason = trashObstacle(old, keeping: kept) {
            log("\(old.path) stays where it is: \(reason)")
            return
        }
        do {
            try FileManager.default.trashItem(at: old, resultingItemURL: nil)
            log("Moved \(old.path) to the Trash")
        } catch {
            log("Cannot move \(old.path) to the Trash: \(error.localizedDescription)")
        }
    }

    /// Why the copy at `old` does not go to the Trash after the move to `kept`; nil when it does.
    nonisolated static func trashObstacle(_ old: URL, keeping kept: URL) -> String? {
        if same(old, kept) { return "it is the copy that stays" }
        let path = normalized(old)
        if path.contains("/.Trash/") || path.contains("/.Trashes/") { return "it is in the Trash already" }
        if isGuarded(old) { return "macOS would first ask the user to let the app into that folder" }
        guard let oldInfo = info(old), let keptInfo = info(kept), let id = oldInfo["CFBundleIdentifier"] as? String,
              id == keptInfo["CFBundleIdentifier"] as? String else { return "it is not the same app" }
        let oldVersion = oldInfo["CFBundleShortVersionString"] as? String ?? "0"
        if compare(oldVersion, keptInfo["CFBundleShortVersionString"] as? String ?? "0") == .orderedDescending { return "it is newer" }
        if (try? old.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return "its volume is read-only" }
        let files = FileManager.default
        guard files.isWritableFile(atPath: old.deletingLastPathComponent().path), files.isWritableFile(atPath: old.path) else {
            return "this user may not move it"
        }
        return nil
    }

    /// In a place macOS guards (Privacy & Security → Files and Folders): before an app changes anything there, macOS
    /// asks the user to let it in. Desktop, Documents, Downloads, iCloud Drive and other cloud folders, other volumes.
    nonisolated static func isGuarded(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = normalized(url), home = normalized(home)
        let folders = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
        return path.hasPrefix("/Volumes/") || folders.contains { path.hasPrefix("\(home)/\($0)/") }
    }

    /// The restart: arguments for /bin/sh that wait for process `pid` to end, open `app` (when there is one), then detach
    /// the disk image at `image` (a few tries: the system may hold it for a moment).
    nonisolated static func relaunchArguments(pid: Int32, app: URL?, detaching image: URL?,
                                              open: String = "/usr/bin/open", hdiutil: String = "/usr/bin/hdiutil") -> [String] {
        let script = """
            while kill -0 "$0" 2>/dev/null; do sleep 0.1; done
            [ -z "$1" ] || "$3" "$1"
            [ -n "$2" ] || exit 0
            for attempt in 1 2 3 4 5 6 7 8 9 10; do "$4" detach "$2" -quiet && exit 0; sleep 1; done
            """
        return ["-c", script, String(pid), app?.path ?? "", image?.path ?? "", open, hdiutil]
    }

    // MARK: Other running copies

    /// How long the other copies get to quit when asked: time to answer a question about unsaved work or an export.
    nonisolated static let othersTimeout: TimeInterval = 30

    /// The other running copies of this app, wherever they run from; never this process.
    static func otherCopies() -> [NSRunningApplication] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != me && isRunning($0) }
    }

    /// Asks the copies to quit the way the user quits them: each one's delegate may ask a question, make the quit wait or
    /// refuse it. Waits up to `timeout` for them to be gone and returns those still running. Nothing is ever forced: a
    /// copy that takes longer counts as one that stayed, and nothing is replaced under it.
    static func askToQuit(_ copies: [NSRunningApplication], timeout: TimeInterval = othersTimeout) async -> [NSRunningApplication] {
        var waiting: [NSRunningApplication] = []
        for copy in copies {
            log("Asking \(copy.bundleURL?.path ?? "another copy") (pid \(copy.processIdentifier)) to quit")
            // In front first, so that a question it asks is seen.
            bringToFront(copy)
            if copy.terminate() { waiting.append(copy) } else { log("pid \(copy.processIdentifier) cannot be asked to quit") }
        }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while waiting.contains(where: isRunning), Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let stayed = copies.filter(isRunning)
        for copy in stayed { log("pid \(copy.processIdentifier) stayed open") }
        return stayed
    }

    /// Not gone: AppKit has not seen it end, and the process is there.
    nonisolated static func isRunning(_ app: NSRunningApplication) -> Bool {
        !app.isTerminated && (kill(app.processIdentifier, 0) == 0 || errno == EPERM)
    }

    /// Brings the copy to the front as it is: activation without a reopen, so it opens no window it would show when
    /// started again.
    static func bringToFront(_ app: NSRunningApplication) {
        if #available(macOS 14, *) { NSApp.yieldActivation(to: app) }
        app.activate(options: [])
    }

    // MARK: Handoff between copies

    /// What a copy leaves for the copy it restarts as, in the defaults the two share.
    struct Handoff: Equatable {
        let from: URL
        let to: URL
        /// `from` opened at login (SMAppService.mainApp).
        let loginItem: Bool
        var time = Date()

        /// Left within the last ten minutes: the copy has just been put where it runs.
        func isRecent(now: Date = Date()) -> Bool { abs(now.timeIntervalSince(time)) < 10 * 60 }
    }

    private nonisolated static let handoffKey = "UpdaterHandoff"

    nonisolated static func record(_ handoff: Handoff, in defaults: UserDefaults = .standard) {
        defaults.set(["from": handoff.from.path, "to": handoff.to.path, "loginItem": handoff.loginItem,
                      "time": handoff.time.timeIntervalSince1970], forKey: handoffKey)
        // The process quits in a moment.
        defaults.synchronize()
    }

    nonisolated static func discardHandoff(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: handoffKey)
    }

    /// The handoff the previous copy left for the copy at `bundle`, however long ago (a quit the user made later may
    /// have finished the move); read once. One left for another copy waits for it, for a month at most.
    nonisolated static func takeHandoff(to bundle: URL, in defaults: UserDefaults = .standard, now: Date = Date()) -> Handoff? {
        guard let record = defaults.dictionary(forKey: handoffKey) else { return nil }
        guard let from = record["from"] as? String, let to = record["to"] as? String, let time = record["time"] as? Double else {
            discardHandoff(in: defaults)
            return nil
        }
        guard same(URL(fileURLWithPath: to), bundle) else {
            if now.timeIntervalSince1970 - time > 30 * 24 * 60 * 60 { discardHandoff(in: defaults) }
            return nil
        }
        discardHandoff(in: defaults)
        return Handoff(from: URL(fileURLWithPath: from), to: URL(fileURLWithPath: to), loginItem: record["loginItem"] as? Bool ?? false,
                       time: Date(timeIntervalSince1970: time))
    }

    /// Run at launch by the copy that has just taken over from another one.
    static func finish(_ handoff: Handoff) {
        log("Took over from \(handoff.from.path)")
        if handoff.loginItem { registerLoginItemAgain() }
    }

    /// The previous copy opened at login: the login item is registered anew from this copy, so that it opens this copy
    /// and not the one left behind (in the Trash, on a detached disk image).
    private static func registerLoginItemAgain() {
        let service = SMAppService.mainApp
        do {
            try? service.unregister()
            try service.register()
            log("Login item registered again for \(Bundle.main.bundleURL.path)")
        } catch {
            log("Cannot register the login item again: \(error.localizedDescription) (status \(service.status.rawValue))")
        }
    }

    // MARK: Paths

    /// The same file system item: symlinks resolved, /System/Volumes/Data in front ignored.
    nonisolated static func same(_ a: URL, _ b: URL) -> Bool { normalized(a) == normalized(b) }

    nonisolated static func normalized(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let data = "/System/Volumes/Data"
        if path == data {
            path = "/"
        } else if path.hasPrefix(data + "/") {
            path.removeFirst(data.count)
        }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private nonisolated static func output(_ tool: String, _ arguments: [String]) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    // MARK: Log

    private nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Updater", category: "updates")
    private nonisolated static let logQueue = DispatchQueue(label: "Updater.log")

    /// Writes to the app's log: Console (category "updates") and ~/Library/Logs/<CFBundleName>.log, the file where
    /// FaceID keeps its own diary. Written at once: the app may quit right after.
    nonisolated static func log(_ message: String) {
        logger.log("\(message, privacy: .public)")
        let now = Date()
        logQueue.sync {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs", isDirectory: true)
            try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            // One write in append mode: a line of the app's own log written meanwhile stays whole.
            let file = Darwin.open(logs.appendingPathComponent("\(appName).log").path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard file >= 0 else { return }
            let line = Array("\(formatter.string(from: now))  Updater: \(message)\n".utf8)
            _ = line.withUnsafeBytes { Darwin.write(file, $0.baseAddress, $0.count) }
            Darwin.close(file)
        }
    }
}
