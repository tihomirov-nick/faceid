import Foundation
import LocalAuthentication
import OpenDirectory
import Security

/// Generic password items in the login keychain. Only apps the keychain trusts for an item read it without asking: the
/// app that created it (checked by its code signature) and apps the user allowed. So the face and the password are
/// hidden from other apps.
///
/// The keychain also remembers which builds may read an item (its partition list): the team for apps signed by Apple,
/// the build's code hash for an app signed with a certificate of its own. Such an app is asked again after every update,
/// and so is any app whose signature changed. FaceID therefore never lets the keychain ask by itself: it reads
/// silently (`interactive: false`) and asks only through `KeychainAccess.confirm()`, while the screen is unlocked.
enum Keychain {
    enum Failure: Error, Equatable {
        case notFound
        /// The keychain wants the user's confirmation (or the user denied it).
        case needsConfirmation
        case other(OSStatus)
    }

    /// The item's data. With `interactive: false` the keychain never shows a prompt: an item that needs the user's
    /// confirmation fails with `.needsConfirmation` instead.
    static func read(service: String, account: String, interactive: Bool) -> Result<Data, Failure> {
        var result: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        let status = quietly(!interactive) { SecItemCopyMatching(query as CFDictionary, &result) }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .failure(.other(status)) }
            return .success(data)
        case errSecItemNotFound:
            return .failure(.notFound)
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            return .failure(.needsConfirmation)
        default:
            return .failure(.other(status))
        }
    }

    /// The item's plain attributes; reading them never needs the user's confirmation.
    static func attributes(service: String, account: String) -> [String: Any]? {
        var result: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        guard quietly(true, { SecItemCopyMatching(query as CFDictionary, &result) }) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }

    static func exists(service: String, account: String) -> Bool {
        attributes(service: service, account: account) != nil
    }

    /// Creates the item or replaces its data (an existing item keeps the apps it trusts).
    @discardableResult
    static func write(_ data: Data, service: String, account: String, label: String, generic: Data? = nil) -> Bool {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        var update: [CFString: Any] = [kSecValueData: data, kSecAttrLabel: label]
        if let generic { update[kSecAttrGeneric] = generic }
        var status = quietly(true) { SecItemUpdate(query as CFDictionary, update as CFDictionary) }
        if status == errSecItemNotFound {
            var item = query
            item.merge(update) { $1 }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    /// False when the item is not there or the keychain does not let FaceID delete it.
    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        return quietly(true) { SecItemDelete(query as CFDictionary) } == errSecSuccess
    }

    // MARK: - Prompts off

    /// Runs `body` with the keychain's prompts turned off for this process when `quiet`. kSecUseAuthenticationUIFail does
    /// not cover the prompts of the login keychain's access lists (they still came up on macOS 26), and
    /// SecKeychainSetUserInteractionAllowed is deprecated, so it is looked up at run time. Silent calls take turns, and the
    /// prompts are turned back on right after each.
    private static func quietly<T>(_ quiet: Bool, _ body: () -> T) -> T {
        guard quiet, let setInteractionAllowed else { return body() }
        lock.lock()
        defer { lock.unlock() }
        _ = setInteractionAllowed(false)
        defer { _ = setInteractionAllowed(true) }
        return body()
    }

    private static let lock = NSLock()

    private static let setInteractionAllowed: (@convention(c) (DarwinBoolean) -> OSStatus)? = {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecKeychainSetUserInteractionAllowed") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (DarwinBoolean) -> OSStatus).self)
    }()

    /// Reads can be made silent on this macOS. Without that, "Allow" cannot be told from "Always Allow" (see
    /// `KeychainAccess.confirm`), and only the check at launch, made while the screen is unlocked, guards the lock screen.
    static var canReadSilently: Bool { setInteractionAllowed != nil }
}

/// The face and the login password of the current user, in one keychain item: after an update the keychain asks once,
/// not twice. Which of the two the item holds is written in a plain attribute, known without decrypting it.
///
/// FaceID 1.0 kept them in two items (`LegacyItems`). Those stay in use as long as FaceID reads them without a prompt,
/// that is while it is signed like FaceID 1.0 (a copy of FaceID 1.0 may still be installed and needs them). They move into
/// the shared item when the keychain has to ask anyway, after a change of signature (`KeychainAccess.confirm`).
enum SecretStore {
    struct Record: Codable, Equatable {
        /// The enrollment (`Enrollment`) as a binary property list.
        var face: Data?
        var password: String?

        var isEmpty: Bool { face == nil && password == nil }

        /// The plain attribute: "face", "password" or both.
        var contents: Data { Data([face != nil ? "face" : nil, password != nil ? "password" : nil].compactMap { $0 }.joined(separator: ",").utf8) }

        static func holds(_ part: String, in contents: Data?) -> Bool {
            contents.map { String(decoding: $0, as: UTF8.self).split(separator: ",").contains(Substring(part)) } ?? false
        }
    }

    static let service = "\(AppPaths.keychainPrefix).secrets"
    static var account: String { NSUserName() }

    static var exists: Bool { Keychain.exists(service: service, account: account) }

    /// FaceID 1.0's two items serve while there is no shared item.
    static var usesLegacyItems: Bool { !exists && LegacyItems.exist }

    /// Never asks the user unless `interactive`.
    static func read(interactive: Bool = false) -> Result<Record, Keychain.Failure> {
        if usesLegacyItems { return LegacyItems.read(interactive: interactive) }
        return Keychain.read(service: service, account: account, interactive: interactive).flatMap { data in
            (try? PropertyListDecoder().decode(Record.self, from: data)).map { .success($0) } ?? .failure(.other(errSecDecode))
        }
    }

    /// Whether the secrets hold `part` ("face" or "password"), from plain attributes.
    static func holds(_ part: String) -> Bool {
        if usesLegacyItems { return Keychain.exists(service: part == "face" ? LegacyItems.face : LegacyItems.password, account: account) }
        return Record.holds(part, in: Keychain.attributes(service: service, account: account)?[kSecAttrGeneric as String] as? Data)
    }

    /// Changes one part and keeps the other. Nothing is written unless the secrets can be read silently first, so a part
    /// is never lost to an item FaceID cannot read.
    @discardableResult
    static func modify(_ change: (inout Record) -> Void) -> Bool {
        var record: Record
        switch read() {
        case let .success(current): record = current
        case .failure(.notFound): record = Record()
        case .failure: return false
        }
        change(&record)
        if usesLegacyItems { return LegacyItems.write(record) }
        // Nothing left: the item goes, or, where the keychain does not let it go, it stays empty.
        if record.isEmpty, Keychain.delete(service: service, account: account) || !exists { return true }
        return write(record)
    }

    /// Writes the shared item.
    static func write(_ record: Record) -> Bool {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(record) else { return false }
        return Keychain.write(data, service: service, account: account, label: L("FaceID — лицо и пароль для разблокировки экрана"),
                              generic: record.contents)
    }
}

/// FaceID 1.0's two items: the face and the login password.
enum LegacyItems {
    static let face = "\(AppPaths.keychainPrefix).face"
    static let password = "\(AppPaths.keychainPrefix).login-password"
    static var account: String { NSUserName() }

    static var exist: Bool {
        Keychain.exists(service: face, account: account) || Keychain.exists(service: password, account: account)
    }

    /// Both items as one record; `.needsConfirmation` if any of them needs the user's confirmation.
    static func read(interactive: Bool) -> Result<SecretStore.Record, Keychain.Failure> {
        var record = SecretStore.Record()
        for service in [face, password] {
            switch Keychain.read(service: service, account: account, interactive: interactive) {
            case let .success(data):
                if service == face { record.face = data } else { record.password = String(data: data, encoding: .utf8) }
            case .failure(.notFound):
                continue
            case let .failure(failure):
                return .failure(failure)
            }
        }
        return .success(record)
    }

    /// Writes both items as FaceID 1.0 did (a part that is gone, goes).
    static func write(_ record: SecretStore.Record) -> Bool {
        var written = true
        if let data = record.face {
            written = Keychain.write(data, service: face, account: account, label: L("FaceID — данные лица")) && written
        } else {
            Keychain.delete(service: face, account: account)
        }
        if let password = record.password {
            written = Keychain.write(Data(password.utf8), service: self.password, account: account,
                                     label: L("FaceID — пароль для разблокировки экрана")) && written
        } else {
            Keychain.delete(service: self.password, account: account)
        }
        return written
    }

    /// Copies both items into a new shared item, which this build owns, and deletes them where the keychain allows
    /// (whatever stays is never read again).
    static func move(_ record: SecretStore.Record) -> Bool {
        guard SecretStore.write(record) else { return false }
        for service in [face, password] where Keychain.exists(service: service, account: account) {
            if !Keychain.delete(service: service, account: account) {
                Log.write("keychain: the old item \(service) stays (the keychain does not let this build delete it)")
            }
        }
        Log.write("keychain: moved the face and the password into one item")
        return true
    }
}

/// Whether FaceID can read its secrets, and the one place where the keychain may ask the user about them.
public enum KeychainAccess {
    public enum State: Equatable {
        /// Nothing saved yet.
        case empty
        case granted
        /// FaceID was updated or signed differently: the keychain wants the user's confirmation once.
        case needsConfirmation
    }

    public enum Confirmation: Equatable {
        case granted
        /// The user denied it, or closed the prompt.
        case denied
        /// "Allow" rather than "Always Allow": it worked this time, the keychain would ask again at the next launch.
        case onlyOnce
    }

    /// Never shows a prompt.
    public static func check() -> State {
        guard SecretStore.exists || LegacyItems.exist else { return .empty }
        if case .success = SecretStore.read() { return .granted }
        return .needsConfirmation
    }

    /// Asks the user through the keychain's own prompts: one for the shared item, or one for each of FaceID 1.0's items,
    /// which then move into a new shared item that this build owns. Blocks while a prompt is up, so call it off the main
    /// thread, and only while the screen is unlocked.
    public static func confirm() -> Confirmation {
        if SecretStore.usesLegacyItems {
            guard case let .success(record) = LegacyItems.read(interactive: true) else { return .denied }
            return LegacyItems.move(record) ? .granted : .denied
        }
        guard case .success = SecretStore.read(interactive: true) else { return .denied }
        // Whether the keychain lets this build in from now on, or only this once.
        if case .success = SecretStore.read() { return .granted }
        return Keychain.canReadSilently ? .onlyOnce : .granted
    }
}

/// The enrolled faces of the current user.
public enum FaceStore {
    public static var exists: Bool { SecretStore.holds("face") }

    /// The saved faces, read without ever asking the user: nil when there are none or the keychain wants a confirmation
    /// first (`KeychainAccess`).
    public static func load() -> Enrollment? {
        guard case let .success(record) = SecretStore.read(), let data = record.face else { return nil }
        return try? PropertyListDecoder().decode(Enrollment.self, from: data)
    }

    @discardableResult
    public static func save(_ enrollment: Enrollment) -> Bool {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(enrollment) else { return false }
        return SecretStore.modify { $0.face = data }
    }

    public static func delete() {
        SecretStore.modify { $0.face = nil }
    }
}

/// The login password FaceID types into the lock screen. It is checked with Open Directory before it is saved.
public enum PasswordStore {
    public static var exists: Bool { SecretStore.holds("password") }

    /// Read without ever asking the user, so the lock screen never shows a keychain prompt: nil when there is no
    /// password or the keychain wants a confirmation first (`KeychainAccess`).
    public static func load() -> String? {
        guard case let .success(record) = SecretStore.read() else { return nil }
        return record.password
    }

    @discardableResult
    public static func save(_ password: String) -> Bool {
        SecretStore.modify { $0.password = password }
    }

    public static func delete() {
        SecretStore.modify { $0.password = nil }
    }

    /// Whether `password` is the current user's login password. A wrong password counts as a failed login
    /// attempt, like a mistake at the login window.
    public static func verify(_ password: String) -> Bool {
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch {
            return false
        }
    }
}

/// Confirms changes to FaceID itself with Touch ID or the login password, as iPhone asks for the passcode
/// before changing Face ID: otherwise anyone at an unlocked Mac could enroll their own face.
public enum OwnerCheck {
    public static func confirm(_ reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
