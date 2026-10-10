import AppKit
import FaceCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var hotspot: NotchHotspot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Nobody sees it, but the password field takes ⌘V, ⌘A and ⌘Z from its Edit menu.
            MainMenu.install()
            AppModel.shared.start()
            // The icon as chosen in the settings, before the updater may copy the bundle elsewhere.
            AppIcon.restore()
            // Also reads `Updater.LoginItem.launchedAtLogin` while the launch event is still there.
            UpdateCenter.shared.start()
            statusItem = StatusItemController.shared
            let hotspot = NotchHotspot()
            hotspot.install()
            self.hotspot = hotspot
            // A scripted debug run opens only what its actions ask for (the controls would take the keyboard from the
            // app in front).
            #if DEBUG
            let scripted = ProcessInfo.processInfo.environment["FACEID_ACTIONS"] != nil
            #else
            let scripted = false
            #endif
            let model = AppModel.shared
            if model.keychainNeedsConfirmation {
                // Updated (or signed differently): the keychain asks once more. FaceID asks it by itself as soon as
                // someone is at the unlocked Mac, with a word in the island; nothing comes out before that.
                if !scripted { KeychainPrompt.shared.wait() }
            } else if !scripted, !model.isEnrolled || !Updater.LoginItem.launchedAtLogin {
                // Not set up yet, or opened by hand: the island comes out with the controls. Started at login or
                // brought back quietly by an update that installed itself, FaceID stays in the notch.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    MainActor.assumeIsolated {
                        // Signed differently: the setup goes on where it stopped, with a permission macOS forgot.
                        let permissionMissing = model.cameraStatus != .authorized || !model.accessibilityTrusted
                        if model.isEnrolled && model.passwordSaved && permissionMissing {
                            Setup.next()
                        } else {
                            Island.shared.show(.home)
                        }
                    }
                }
            }
        }
        #if DEBUG
        DebugHooks.install()
        #endif
    }

    /// Opening the app again (Finder, Spotlight) brings out the controls.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { Island.shared.toggleHome() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The updater relaunches FaceID by quitting it; that waits while the screen is locked or FaceID is busy, and an
    /// automatic restart first shows "Updating to version X…" for a moment.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { UpdateCenter.shared.terminationReply() }
    }
}
