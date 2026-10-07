import AppKit
import CryptoKit
import FaceCore
import Foundation
import Security

/// Installs the sudo module: /usr/local/lib/pam/pam_faceid.so, its settings in /usr/local/etc/faceid/pam.conf
/// (the code signature FaceID must have) and a line in /etc/pam.d/sudo_local, the file macOS keeps across
/// updates. Needs the administrator password, and Full Disk Access where macOS guards /etc/pam.d.
///
/// The shell script that runs as root is compiled into the app (so nobody can edit it in the bundle), and the
/// module is checked against a SHA-256 taken after verifying the app's own signature: a module swapped inside the
/// bundle is never installed.
enum PamInstaller {
    enum State: Equatable {
        case notInstalled
        case installed
        /// Installed by another build of FaceID: the module or the signature it trusts differ.
        case needsUpdate
        /// No /etc/pam.d/sudo_local support (macOS before 14).
        case unsupported
    }

    enum Failure: LocalizedError {
        case moduleMissing
        case signatureBroken
        case script(String)
        case cancelled
        /// macOS needs Full Disk Access for FaceID before /etc/pam.d can be changed.
        case diskAccess

        var errorDescription: String? {
            switch self {
            case .moduleMissing: L("В приложении нет модуля pam_faceid.so")
            case .signatureBroken: L("Подпись FaceID повреждена, поэтому модуль не установлен. Скачайте приложение заново")
            case let .script(message): message
            case .cancelled: L("Отменено")
            case .diskAccess: L("Нужен «Полный доступ к диску»")
            }
        }
    }

    /// The module shipped in Contents/Resources (development builds: build/pam_faceid.so in the repository).
    static var bundledModule: URL? {
        if let url = AppPaths.resource("pam_faceid.so") { return url }
        guard let root = AppPaths.devRoot else { return nil }
        let url = root.appendingPathComponent("build/pam_faceid.so")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func state() -> State {
        let fm = FileManager.default
        guard fm.fileExists(atPath: "/etc/pam.d/sudo_local.template") || fm.fileExists(atPath: SudoProtocol.sudoLocalPath) else {
            return .unsupported
        }
        guard fm.fileExists(atPath: SudoProtocol.modulePath),
              let local = try? String(contentsOfFile: SudoProtocol.sudoLocalPath, encoding: .utf8),
              local.split(separator: "\n").contains(where: isActiveLine) else { return .notInstalled }
        guard let requirement = currentRequirement,
              let config = try? String(contentsOfFile: SudoProtocol.configPath, encoding: .utf8),
              config.split(separator: "\n").contains(where: { $0 == "requirement=\(requirement)" }),
              let bundled = bundledModule, sha256(bundled) == sha256(URL(fileURLWithPath: SudoProtocol.modulePath)) else {
            return .needsUpdate
        }
        return .installed
    }

    static func isActiveLine(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("#") && trimmed.contains(SudoProtocol.modulePath)
    }

    /// The designated requirement of this build ("identifier … and certificate …", or a cdhash for ad-hoc builds).
    static var currentRequirement: String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    /// The app on disk is exactly what was signed (resources included, so the bundled module too).
    static var ownSignatureIsValid: Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess
    }

    /// FaceID has Full Disk Access: the privacy database opens only with it. A permission check such as
    /// `isReadableFile` says yes either way: the file is readable by everyone and macOS refuses only the open.
    static var hasDiskAccess: Bool {
        let file = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard file >= 0 else { return false }
        close(file)
        return true
    }

    static func sha256(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    static func install() throws {
        guard let module = bundledModule, let hash = sha256(module), let requirement = currentRequirement else {
            throw Failure.moduleMissing
        }
        guard ownSignatureIsValid else { throw Failure.signatureBroken }
        try runAsRoot(["install", module.path, hash, requirement],
                      prompt: L("FaceID хочет подключить распознавание лица к sudo"))
        Log.write("sudo module installed")
    }

    @MainActor
    static func uninstall() throws {
        try runAsRoot(["uninstall"], prompt: L("FaceID хочет отключить распознавание лица в sudo"))
        Log.write("sudo module removed")
    }

    /// Runs the setup script as root after the administrator password dialog.
    @MainActor
    private static func runAsRoot(_ arguments: [String], prompt: String) throws {
        let command = (["/bin/sh", "-c", script, "faceid-sudo-setup"] + arguments).map(shellQuoted).joined(separator: " ")
        let source = "do shell script \"\(appleScriptEscaped(command))\" with administrator privileges with prompt \"\(appleScriptEscaped(prompt))\""
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            switch error[NSAppleScript.errorNumber] as? Int {
            case -128: throw Failure.cancelled
            case 3: throw Failure.script(L("В папки /usr/local может писать не только root, поэтому ставить туда модуль sudo небезопасно"))
            case 4: throw Failure.diskAccess
            case 5:
                Log.write("sudo module rejected: \((error[NSAppleScript.errorMessage] as? String) ?? "")")
                throw Failure.script(L("sudo не принял модуль FaceID, настройки sudo остались прежними"))
            default: throw Failure.script((error[NSAppleScript.errorMessage] as? String) ?? L("Не удалось изменить настройки sudo"))
            }
        }
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Runs as root. Order matters: install puts the module in place before sudo_local mentions it, uninstall
    /// removes the line first: a sudo_local line pointing at a module sudo cannot load may break sudo. For the same
    /// reason install ends by starting sudo and takes the line out again if sudo fails.
    static let script = #"""
    set -eu
    MODULE=/usr/local/lib/pam/pam_faceid.so
    CONFIG=/usr/local/etc/faceid/pam.conf
    LOCAL=/etc/pam.d/sudo_local
    TEMPLATE=/etc/pam.d/sudo_local.template
    LINE="auth       sufficient     $MODULE"

    # macOS lets a program change /etc/pam.d only with Full Disk Access, so sudo_local (the file Apple leaves for
    # local changes) is the only thing written there; the new text is prepared outside. Exit 4: access denied.
    write_local() {
        if ! cat "$1" > "$LOCAL" 2>/dev/null; then
            rm -f "$1"
            echo "no access to $LOCAL" >&2
            exit 4
        fi
        rm -f "$1"
        chown root:wheel "$LOCAL"
        chmod 444 "$LOCAL"
    }

    remove_line() {
        if [ -f "$LOCAL" ] && grep -qF "$MODULE" "$LOCAL"; then
            NEW="$(mktemp /tmp/faceid-sudo_local.XXXXXX)"
            grep -vF "$MODULE" "$LOCAL" > "$NEW" || true
            write_local "$NEW"
        fi
    }

    case "$1" in
    install)
        SOURCE="$2"; HASH="$3"; REQUIREMENT="$4"
        install -d -o root -g wheel -m 755 /usr/local/lib/pam /usr/local/etc/faceid
        # sudo loads the module as root: every folder on the way must belong to root alone, or another user could
        # swap the module (an old Intel Homebrew, for instance, makes /usr/local/lib the user's).
        for dir in /usr /usr/local /usr/local/lib /usr/local/lib/pam /usr/local/etc /usr/local/etc/faceid; do
            if [ "$(stat -f %u "$dir")" != 0 ] || [ $(( 0$(stat -f %Lp "$dir") & 022 )) -ne 0 ]; then
                echo "$dir is writable by someone other than root" >&2
                exit 3
            fi
        done
        # Copy first and check the copy: the file in the app cannot be swapped between the check and the copy.
        cp -f "$SOURCE" "$MODULE.new"
        if [ "$(shasum -a 256 "$MODULE.new" | awk '{print $1}')" != "$HASH" ]; then
            rm -f "$MODULE.new"
            echo "pam_faceid.so: checksum mismatch" >&2
            exit 2
        fi
        chown root:wheel "$MODULE.new"
        chmod 444 "$MODULE.new"
        mv -f "$MODULE.new" "$MODULE"
        printf 'requirement=%s\n' "$REQUIREMENT" > "$CONFIG.new"
        chown root:wheel "$CONFIG.new"
        chmod 644 "$CONFIG.new"
        mv -f "$CONFIG.new" "$CONFIG"
        CURRENT="$(mktemp /tmp/faceid-sudo_local.XXXXXX)"
        if [ -f "$LOCAL" ]; then
            cp -f "$LOCAL" "$CURRENT"
            cp -f "$LOCAL" /usr/local/etc/faceid/sudo_local.backup
        elif [ -f "$TEMPLATE" ]; then
            cp -f "$TEMPLATE" "$CURRENT"
        else
            printf '# sudo_local: local config file which survives system update and is included for sudo\n' > "$CURRENT"
        fi
        if grep -v '^[[:space:]]*#' "$CURRENT" | grep -qF "$MODULE"; then
            rm -f "$CURRENT"
        else
            NEW="$(mktemp /tmp/faceid-sudo_local.XXXXXX)"
            # Before Touch ID (pam_tid), so the face is tried first; pam_reattach, if any, stays above both.
            awk -v line="$LINE" '!done && /^[[:space:]]*auth.*pam_tid\.so/ { print line; done = 1 } { print } END { if (!done) print line }' \
                "$CURRENT" > "$NEW"
            rm -f "$CURRENT"
            write_local "$NEW"
        fi
        # sudo reads its PAM settings and loads every module in them on each start, root's included (root is
        # never asked for a password). If it fails now, the line goes and sudo works as before. Exit 5.
        if ! OUTPUT="$(/usr/bin/sudo -n /usr/bin/true 2>&1)"; then
            remove_line
            echo "sudo fails with pam_faceid.so: $OUTPUT" >&2
            exit 5
        fi
        ;;
    uninstall)
        remove_line
        rm -f "$MODULE" "$CONFIG" /usr/local/etc/faceid/sudo_local.backup
        rmdir /usr/local/etc/faceid 2>/dev/null || true
        ;;
    *)
        echo "usage: install <module> <sha256> <requirement> | uninstall" >&2
        exit 64
        ;;
    esac
    """#
}
