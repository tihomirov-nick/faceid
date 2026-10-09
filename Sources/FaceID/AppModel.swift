import AppKit
import AVFoundation
import FaceCore
import Foundation

/// App state shared by the windows, the menu and the services: the enrolled face, permissions, status.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings = AppSettings.shared
    @Published private(set) var enrollment: Enrollment?
    @Published private(set) var passwordSaved = false
    @Published private(set) var cameraStatus = Camera.authorizationStatus
    @Published private(set) var accessibilityTrusted = LockScreen.canType
    /// A problem to show in the controls for a moment (a face the keychain would not save, say).
    @Published var message: String?
    /// The typed password did not unlock the screen: it probably changed.
    @Published var passwordProblem = false
    /// Scans running now (the auto-lock camera pauses for them).
    @Published private(set) var activeScans = 0
    /// The keychain wants the user's confirmation before FaceID may read its face and password: FaceID was updated or
    /// signed differently. Until then FaceID does not unlock; `confirmKeychain()` asks while the screen is unlocked.
    @Published private(set) var keychainNeedsConfirmation = false
    /// FaceID started on the lock screen and has not read the keychain yet (it waits until the screen is unlocked).
    private(set) var secretsDeferred = false

    let unlock = UnlockService()
    let presence = PresenceService()

    private init() {}

    var isEnrolled: Bool { enrollment != nil }

    /// Everything the lock screen needs: a face, the password, permission to type it, and a keychain that lets FaceID read
    /// them without asking.
    var canUnlock: Bool {
        isEnrolled && passwordSaved && accessibilityTrusted && cameraStatus == .authorized && !keychainNeedsConfirmation
    }

    func start() {
        loadSecrets()
        refresh()
        unlock.start(model: self)
        presence.start(model: self)
        Log.write("FaceID started · face: \(isEnrolled) · password: \(passwordSaved) · accessibility: \(accessibilityTrusted)"
            + (keychainNeedsConfirmation ? " · the keychain needs a confirmation" : secretsDeferred ? " · keychain after unlocking" : ""))
    }

    /// Reads the faces without ever letting the keychain ask. On the lock screen it does not even try: after an update the
    /// keychain may want a confirmation, and that is asked only once the screen is unlocked.
    func loadSecrets() {
        guard !LockScreen.isLocked else {
            secretsDeferred = true
            return
        }
        secretsDeferred = false
        switch KeychainAccess.check() {
        case .empty:
            enrollment = nil
            keychainNeedsConfirmation = false
        case .granted:
            enrollment = FaceStore.load()
            keychainNeedsConfirmation = false
        case .needsConfirmation:
            enrollment = nil
            keychainNeedsConfirmation = true
        }
        passwordSaved = PasswordStore.exists
        if isEnrolled { FaceEngine.preload() }
    }

    /// The keychain's own prompts (see `KeychainAccess.confirm`), off the main thread so that the island stays alive while
    /// one is up. Only while the screen is unlocked.
    func confirmKeychain() async -> KeychainAccess.Confirmation {
        guard !LockScreen.isLocked else { return .denied }
        let result = await Task.detached { KeychainAccess.confirm() }.value
        Log.write("keychain: confirmation \(result)")
        loadSecrets()
        return keychainNeedsConfirmation && result == .granted ? .denied : result
    }

    /// The keychain turned FaceID away where it should not have (the lock screen, a save): it is checked again, on the
    /// lock screen only once the screen is unlocked.
    func keychainRefused() {
        guard !keychainNeedsConfirmation else { return }
        if LockScreen.isLocked {
            secretsDeferred = true
        } else if KeychainAccess.check() == .needsConfirmation {
            keychainNeedsConfirmation = true
            Log.write("keychain: needs a confirmation")
        }
    }

    /// Permissions can change outside the app; checked when the controls open.
    func refresh() {
        cameraStatus = Camera.authorizationStatus
        accessibilityTrusted = LockScreen.canType
        Updater.LoginItem.shared.refresh()
        passwordSaved = PasswordStore.exists
    }

    // MARK: - Face

    func save(_ enrollment: Enrollment) {
        guard FaceStore.save(enrollment) else {
            show(L("Не удалось сохранить лицо в Связке ключей"))
            keychainRefused()
            return
        }
        self.enrollment = enrollment
        FaceEngine.preload()
        Log.write("faces saved: \(enrollment.faces.count), \(enrollment.templates.count) shots")
    }

    /// Removes one face; removing the last one is a reset.
    func removeFace(_ id: Int) {
        guard let enrollment else { return }
        if let updated = enrollment.removing(face: id) {
            save(updated)
        } else {
            resetFace()
        }
    }

    func renameFace(_ id: Int, to name: String) {
        guard let enrollment else { return }
        save(enrollment.renaming(face: id, to: name))
    }

    /// "Reset Face ID": forgets every face (the saved password stays until "Forget Password").
    func resetFace() {
        FaceStore.delete()
        enrollment = nil
        settings.autoLockEnabled = false
        Log.write("face deleted")
    }

    /// After a sure match FaceID keeps the fresh shot, so it follows gradual changes of the face like Face ID
    /// on iPhone (up to 12 such shots; see `Enrollment.learning`).
    func learn(_ embedding: [Float], similarity: Float) {
        guard let enrollment, similarity >= settings.strictness.threshold + 0.08,
              let updated = enrollment.learning(embedding), FaceStore.save(updated) else { return }
        self.enrollment = updated
        Log.write(String(format: "learned a new shot of the face (similarity %.2f)", similarity))
    }

    #if DEBUG
    /// Debug hooks only: a face that is shown in the windows but never saved.
    func setEnrollmentForDebugging(_ enrollment: Enrollment) {
        self.enrollment = enrollment
    }

    /// Debug hooks only: a set-up FaceID in memory, the face given and the password and permissions counted as there,
    /// so the controls can be drawn offscreen as after setup. Nothing is saved.
    func setReadyForDebugging(_ enrollment: Enrollment) {
        self.enrollment = enrollment
        passwordSaved = true
        cameraStatus = .authorized
        accessibilityTrusted = true
        keychainNeedsConfirmation = false
    }
    #endif

    // MARK: - Owner

    private var ownerConfirmedAt: Date?

    /// Touch ID or the login password before setting up a face or weakening FaceID (iPhone asks for the passcode
    /// the same way); one confirmation lasts a minute. The island stays open behind the system dialog.
    func confirmOwner() async -> Bool {
        if let at = ownerConfirmedAt, Date().timeIntervalSince(at) < 60 { return true }
        Island.shared.keepOpen = true
        defer { Island.shared.keepOpen = false }
        guard await OwnerCheck.confirm(L("изменить настройки FaceID")) else { return false }
        ownerConfirmedAt = Date()
        return true
    }

    // MARK: - Password

    /// Checks the password with Open Directory and keeps it in the Keychain.
    func savePassword(_ password: String) async -> Bool {
        let valid = await Task.detached { PasswordStore.verify(password) }.value
        guard valid, PasswordStore.save(password) else { return false }
        passwordSaved = true
        passwordProblem = false
        Log.write("login password saved")
        return true
    }

    func forgetPassword() {
        PasswordStore.delete()
        passwordSaved = false
    }

    // MARK: - Permissions

    // macOS keeps the camera and Accessibility permissions by the app's signature. A record made for a build signed
    // differently stays in System Settings, but it no longer counts, its switch does nothing, and macOS does not ask
    // again while it is there. So when a permission is missing, the request first resets FaceID's record, and macOS's own
    // prompt makes a new one for this build: for Accessibility a new FaceID row, switched off, so the user only turns it
    // on. `PermissionWatcher` notices and goes on with the setup.

    func requestCamera() {
        Task {
            await askForCamera()
            if cameraStatus == .denied { openPrivacySettings("Privacy_Camera") }
        }
    }

    /// macOS's camera prompt, after resetting a record left by another build.
    func askForCamera() async {
        if !Camera.isAuthorized { await Self.resetPermission("Camera") }
        _ = await Camera.requestAccess()
        refresh()
    }

    func requestAccessibility() {
        Task {
            if !LockScreen.canType { await Self.resetPermission("Accessibility") }
            LockScreen.requestAccessibility()
            openPrivacySettings("Privacy_Accessibility")
        }
    }

    /// `tccutil reset <service> <bundle id>`: forgets FaceID's record for the permission, whichever build it was made for
    /// (no admin rights needed). Only the app has a bundle id; a build run straight from the package has none.
    private static func resetPermission(_ service: String) async {
        guard Bundle.main.bundleURL.pathExtension == "app", let id = Bundle.main.bundleIdentifier else { return }
        let status = await Task.detached { () -> Int32 in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, id]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return -1 }
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        Log.write("permissions: \(service) record reset before asking" + (status == 0 ? "" : " (tccutil failed: \(status))"))
    }

    func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Scans

    /// A scan with the current settings; nil until a face is enrolled.
    func makeScan(timeout: TimeInterval, policy: ScanPolicy? = nil) -> ScanSession? {
        guard let enrollment else { return nil }
        return ScanSession(enrollment: enrollment, policy: policy ?? settings.policy,
                           allowExternalCamera: settings.allowExternalCamera, timeout: timeout)
    }

    func scanStarted() { activeScans += 1 }
    func scanEnded() { activeScans = max(0, activeScans - 1) }

    /// Shows `text` in the controls for a few seconds.
    func show(_ text: String) {
        message = text
        Log.write("message: \(text)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated {
                if self?.message == text { self?.message = nil }
            }
        }
    }
}
