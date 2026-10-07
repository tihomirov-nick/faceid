import Foundation
import os

/// A short diary of what FaceID did (scans, unlocks, sudo requests) in ~/Library/Logs/FaceID.log and in Console.
/// Never contains the password or face data.
public enum Log {
    private static let logger = Logger(subsystem: AppPaths.bundleID, category: "app")
    private static let queue = DispatchQueue(label: "com.faceid.log")
    private static let maxSize = 1_000_000

    public static var fileURL: URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
        return AppPaths.ensureDir(logs).appendingPathComponent("\(AppPaths.storageName).log")
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    public static func write(_ message: String) {
        logger.log("\(message, privacy: .public)")
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async {
            let url = fileURL
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxSize {
                let old = url.deletingPathExtension().appendingPathExtension("old.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
