import AppKit
import AVFoundation
import FaceCore
import Foundation
import ServiceManagement

/// App state shared by the windows, the menu and the services: the enrolled face, permissions, status.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings = AppSettings.shared
    @Published private(set) var enrollment: Enrollment?
    @Published private(set) var passwordSaved = false
    @Published private(set) var cameraStatus = Camera.authorizationStatus
    @Published private(set) var accessibilityTrusted = LockScreen.canType
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// A problem to show in the controls for a moment (a face the keychain would not save, say).
    @Published var message: String?
    /// The typed password did not unlock the screen: it probably changed.
    @Published var passwordProblem = false
    /// Scans running now (the auto-lock camera pauses for them).
    @Published private(set) var activeScans = 0

    let unlock = UnlockService()
    let presence = PresenceService()

    private init() {}

    var isEnrolled: Bool { enrollment != nil }

    /// Everything the lock screen needs: a face, the password and permission to type it.
    var canUnlock: Bool { isEnrolled && passwordSaved && accessibilityTrusted && cameraStatus == .authorized }

    func start() {
        enrollment = FaceStore.load()
        passwordSaved = PasswordStore.exists
        refresh()
        if isEnrolled { FaceEngine.preload() }
        unlock.start(model: self)
        presence.start(model: self)
        Log.write("FaceID started · face: \(isEnrolled) · password: \(passwordSaved) · accessibility: \(accessibilityTrusted)")
    }

    /// Permissions can change outside the app; checked when the controls open.
    func refresh() {
        cameraStatus = Camera.authorizationStatus
        accessibilityTrusted = LockScreen.canType
        launchAtLogin = SMAppService.mainApp.status == .enabled
        passwordSaved = PasswordStore.exists
    }

    // MARK: - Face

    func save(_ enrollment: Enrollment) {
        guard FaceStore.save(enrollment) else {
            show(L("Не удалось сохранить лицо в Связке ключей"))
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

    func requestCamera() {
        Task {
            _ = await Camera.requestAccess()
            refresh()
            if cameraStatus == .denied { openPrivacySettings("Privacy_Camera") }
        }
    }

    func requestAccessibility() {
        LockScreen.requestAccessibility()
        openPrivacySettings("Privacy_Accessibility")
    }

    func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            show(error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
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
