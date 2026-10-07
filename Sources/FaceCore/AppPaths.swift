import CoreML
import Foundation

/// File system locations used by the app.
public enum AppPaths {
    public static let appName = "FaceID"
    public static let bundleID = "com.faceid.app"

    /// Development builds keep their own keychain items, socket and log: running one never touches the faces,
    /// the password or the sudo socket of the installed app.
    #if DEBUG
    public static let storageName = "FaceID Debug"
    public static let keychainPrefix = "\(bundleID).debug"
    #else
    public static let storageName = appName
    public static let keychainPrefix = bundleID
    #endif

    /// ~/Library/Application Support/FaceID (things that are not secret: the sudo socket).
    /// `FACEID_SUPPORT_DIR` points to another folder (for tests).
    public static var supportDir: URL {
        if let custom = ProcessInfo.processInfo.environment["FACEID_SUPPORT_DIR"], !custom.isEmpty {
            return ensureDir(URL(fileURLWithPath: custom, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensureDir(base.appendingPathComponent(storageName, isDirectory: true))
    }

    /// Compiled Core ML models made from `Resources/*.mlpackage` in development builds.
    static var modelCacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ensureDir(base.appendingPathComponent("\(bundleID)/Models", isDirectory: true))
    }

    @discardableResult
    static func ensureDir(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Bundled resources

    /// Repository root when running from `.build` during development (directory containing Package.swift).
    public static let devRoot: URL? = {
        var url = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<10 {
            guard let current = url else { return nil }
            if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
                return current
            }
            url = current.deletingLastPathComponent()
        }
        return nil
    }()

    /// A file from the app's Contents/Resources, or from `Resources/` in the repository during development.
    public static func resource(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent(name)) }
        if let root = devRoot { candidates.append(root.appendingPathComponent("Resources").appendingPathComponent(name)) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The face recognition model: SFace.mlmodelc in the app, or Resources/SFace.mlpackage compiled on first use.
    public static func recognitionModelURL() -> URL? {
        compiledModel("SFace")
    }

    /// The anti-spoofing models (MiniFASNet), see `SpoofDetector`.
    public static func spoofModelURL(_ name: String) -> URL? {
        compiledModel(name)
    }

    private static let compileLock = NSLock()

    static func compiledModel(_ name: String) -> URL? {
        if let compiled = resource("\(name).mlmodelc") { return compiled }
        guard let package = resource("\(name).mlpackage") else { return nil }
        compileLock.lock()
        defer { compileLock.unlock() }
        // Recompile when the package changes (its modification date is part of the cache name).
        let stamp = (try? package.appendingPathComponent("Manifest.json").resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate?.timeIntervalSince1970).map { Int($0) } ?? 0
        let cached = modelCacheDir.appendingPathComponent("\(name)-\(stamp).mlmodelc")
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        guard let temporary = try? MLModel.compileModel(at: package) else { return nil }
        try? FileManager.default.removeItem(at: cached)
        do {
            try FileManager.default.moveItem(at: temporary, to: cached)
        } catch {
            return temporary
        }
        return cached
    }
}
