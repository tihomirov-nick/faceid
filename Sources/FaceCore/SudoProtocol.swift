import Foundation

/// How the PAM module (PAM/pam_faceid.c, loaded by sudo) talks to the FaceID app over a Unix socket:
///
///     module → app:  FACEID 1\n  key=value\n …  \n          (values escaped: \\ and \n)
///     app → module:  INFO <text>\n …                        (messages for the terminal)
///                    OK\n | DENY <text>\n                   (the answer)
///
/// Keys: user, service, tty, pid, ruser, command. The module checks that the socket belongs to the user and
/// that the code signature of the process behind it matches FaceID; the app checks that the client is root
/// and is /usr/bin/sudo.
public enum SudoProtocol {
    public static let magic = "FACEID 1"

    /// ~/Library/Application Support/FaceID/sudo.sock (the module builds the same path from the user's home;
    /// development builds use "FaceID Debug" and scripts/test_pam.sh points its test module there).
    public static var socketURL: URL { AppPaths.supportDir.appendingPathComponent("sudo.sock") }

    /// Where the installer puts the module and its settings (owned by root).
    public static let modulePath = "/usr/local/lib/pam/pam_faceid.so"
    public static let configPath = "/usr/local/etc/faceid/pam.conf"
    public static let sudoLocalPath = "/etc/pam.d/sudo_local"
    /// The line added to /etc/pam.d/sudo_local.
    public static let pamLine = "auth       sufficient     \(modulePath)"

    public struct Request: Equatable, Sendable {
        public var fields: [String: String]
        public var user: String { fields["user"] ?? "" }
        public var service: String { fields["service"] ?? "" }
        public var tty: String { fields["tty"] ?? "" }
        public var command: String { fields["command"] ?? "" }
        public var pid: pid_t? { fields["pid"].flatMap { pid_t($0) } }
    }

    /// Parses a request; nil when it is malformed or incomplete (no empty line at the end yet).
    public static func parse(_ text: String) -> Request? {
        guard let end = text.range(of: "\n\n") else { return nil }
        let lines = text[..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == magic else { return nil }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let equals = line.firstIndex(of: "=") else { return nil }
            fields[String(line[..<equals])] = unescape(String(line[line.index(after: equals)...]))
        }
        return Request(fields: fields)
    }

    public static func encode(_ fields: [(String, String)]) -> String {
        ([magic] + fields.map { "\($0.0)=\(escape($0.1))" }).joined(separator: "\n") + "\n\n"
    }

    public static func info(_ text: String) -> String { "INFO \(oneLine(text))\n" }
    public static let ok = "OK\n"
    public static func deny(_ text: String) -> String { "DENY \(oneLine(text))\n" }

    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
    }

    static func unescape(_ value: String) -> String {
        var out = ""
        var iterator = value.makeIterator()
        while let c = iterator.next() {
            guard c == "\\", let next = iterator.next() else { out.append(c); continue }
            out.append(next == "n" ? "\n" : next)
        }
        return out
    }
}
