import Foundation
import LocalAuthentication
import OpenDirectory
import Security

/// Generic password items in the login keychain. Only the app that created an item reads it without asking
/// (the keychain checks the code signature), so the face and the password are hidden from other apps.
enum Keychain {
    static func read(service: String, account: String) -> Data? {
        var result: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func exists(service: String, account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        // Attributes only: reading them never shows a keychain prompt.
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func write(_ data: Data, service: String, account: String, label: String) -> Bool {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let update: [CFString: Any] = [kSecValueData: data, kSecAttrLabel: label]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(update) { $1 }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    static func delete(service: String, account: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// The enrolled face of the current user.
public enum FaceStore {
    static let service = "\(AppPaths.keychainPrefix).face"
    static var account: String { NSUserName() }

    public static var exists: Bool { Keychain.exists(service: service, account: account) }

    public static func load() -> Enrollment? {
        guard let data = Keychain.read(service: service, account: account) else { return nil }
        return try? PropertyListDecoder().decode(Enrollment.self, from: data)
    }

    @discardableResult
    public static func save(_ enrollment: Enrollment) -> Bool {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(enrollment) else { return false }
        return Keychain.write(data, service: service, account: account, label: L("FaceID — данные лица"))
    }

    public static func delete() {
        Keychain.delete(service: service, account: account)
    }
}

/// The login password FaceID types into the lock screen. It is checked with Open Directory before it is saved.
public enum PasswordStore {
    static let service = "\(AppPaths.keychainPrefix).login-password"
    static var account: String { NSUserName() }

    public static var exists: Bool { Keychain.exists(service: service, account: account) }

    public static func load() -> String? {
        Keychain.read(service: service, account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    public static func save(_ password: String) -> Bool {
        Keychain.write(Data(password.utf8), service: service, account: account, label: L("FaceID — пароль для разблокировки экрана"))
    }

    public static func delete() {
        Keychain.delete(service: service, account: account)
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
