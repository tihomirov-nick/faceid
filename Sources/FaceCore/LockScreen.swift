import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// The macOS lock screen: its state, waking the display, locking, and typing the password into it.
public enum LockScreen {
    static var session: [String: Any] {
        (CGSessionCopyCurrentDictionary() as? [String: Any]) ?? [:]
    }

    /// The screen is locked (the lock screen is up, possibly with the display asleep).
    public static var isLocked: Bool {
        (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    /// The process that turned on secure keyboard input (a focused password field), if any.
    public static var secureInputPID: pid_t? {
        (session["kCGSSessionSecureInputPID"] as? NSNumber).map { pid_t($0.int32Value) }
    }

    public static var loginWindowPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow").first?.processIdentifier
    }

    /// The password field of the lock screen has the keyboard: the screen is locked and secure input belongs to
    /// loginwindow, or nobody has secure input and Accessibility reports loginwindow as the focused app. Only then
    /// may the password be typed: if another app holds secure input (Terminal's Secure Keyboard Entry, say),
    /// the keys could go there.
    public static var passwordFieldHasFocus: Bool {
        guard isLocked, let loginWindow = loginWindowPID else { return false }
        if let owner = secureInputPID { return owner == loginWindow }
        return focusedAppPID == loginWindow
    }

    /// The app Accessibility considers focused (needs the Accessibility permission).
    public static var focusedAppPID: pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(value as! AXUIElement, &pid) == .success ? pid : nil
    }

    /// The facts the typing decision rests on, for the log.
    public static var focusDiagnostics: String {
        func text(_ pid: pid_t?) -> String { pid.map(String.init) ?? "-" }
        return "locked \(isLocked) · secure input \(text(secureInputPID)) · loginwindow \(text(loginWindowPID)) · focused \(text(focusedAppPID))"
    }

    public static var displayIsAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    public static var screenSaverIsRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenSaver.Engine").contains { !$0.isTerminated }
    }

    /// Seconds since the last keyboard, mouse or trackpad input (works while the screen is locked).
    public static var secondsSinceInput: Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    public static var secondsSinceKeyPress: Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    }

    /// Wakes the display as if the user touched the keyboard.
    public static func wakeDisplay() {
        var assertion: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("FaceID" as CFString, kIOPMUserActiveLocal, &assertion)
        IOPMAssertionRelease(assertion)
    }

    /// Locks the screen at once (the same call as the Lock Screen menu item); falls back to ⌃⌘Q.
    public static func lock() {
        typealias LockFunction = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            _ = unsafeBitCast(symbol, to: LockFunction.self)()
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: down) // Q
            event?.flags = [.maskCommand, .maskControl]
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Typing the password

    /// Synthetic keyboard input needs the Accessibility permission.
    public static var canType: Bool { AXIsProcessTrusted() }

    public static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public enum TypingResult: Equatable {
        case typed
        case notLocked
        case fieldNotFocused
        case noPermission
    }

    /// Clears the password field, types `password` and presses Return. Re-checks before every step that the
    /// lock screen still has the keyboard (`passwordFieldHasFocus`) and stops otherwise: a password typed into
    /// another app would be exposed.
    public static func type(password: String) -> TypingResult {
        guard canType else { return .noPermission }
        func ready() -> TypingResult? {
            guard isLocked else { return .notLocked }
            return passwordFieldHasFocus ? nil : .fieldNotFocused
        }
        if let problem = ready() { return problem }
        let source = CGEventSource(stateID: .hidSystemState)
        func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
            }
        }
        // Whatever the user already typed (the key that woke the screen): select all and delete.
        press(0, flags: .maskCommand) // ⌘A
        press(51)                     // Delete
        usleep(30_000)
        let units = Array(password.utf16)
        var index = 0
        while index < units.count {
            if let problem = ready() { return problem }
            // Up to 20 characters per key event; the key code carries no meaning, the Unicode string does.
            let chunk = Array(units[index..<min(index + 20, units.count)])
            let down = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true)
            chunk.withUnsafeBufferPointer { down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
            down?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
            index += chunk.count
            usleep(10_000)
        }
        if let problem = ready() { return problem }
        press(36) // Return
        return .typed
    }
}
