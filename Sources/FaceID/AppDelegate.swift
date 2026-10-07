import AppKit
import FaceCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var hotspot: NotchHotspot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.start()
            statusItem = StatusItemController()
            let hotspot = NotchHotspot()
            hotspot.install()
            self.hotspot = hotspot
            // Not set up yet, or opened by hand (not at login): the island comes out with the controls.
            if !AppModel.shared.isEnrolled || !Self.launchedAtLogin {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    MainActor.assumeIsolated { Island.shared.show(.home) }
                }
            }
        }
        #if DEBUG
        DebugHooks.install()
        #endif
    }

    /// Started as a login item: the Apple Event says so (classic login items), or the user logged in at the
    /// console a moment ago (SMAppService login items get no such flag).
    static var launchedAtLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem { return true }
        var loginTime: Date?
        setutxent()
        while let entry = getutxent() {
            let record = entry.pointee
            guard record.ut_type == USER_PROCESS else { continue }
            let user = withUnsafeBytes(of: record.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let line = withUnsafeBytes(of: record.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if user == NSUserName(), line == "console" {
                loginTime = Date(timeIntervalSince1970: Double(record.ut_tv.tv_sec))
            }
        }
        endutxent()
        return loginTime.map { Date().timeIntervalSince($0) < 90 } ?? false
    }

    /// Opening the app again (Finder, Spotlight) brings out the controls.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { Island.shared.toggleHome() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
