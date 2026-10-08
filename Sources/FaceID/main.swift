import AppKit
import FaceCore

// FaceID has no windows of its own: it lives in the menu bar and in the island under the notch.
Localization.apply()
#if DEBUG
// Debug hooks: FACEID_RENDER=<png> draws the island's states offscreen and quits before anything shows up on screen.
if let path = ProcessInfo.processInfo.environment["FACEID_RENDER"] {
    // Drawing only: an app that may never become active or show a window, so the app in front keeps the focus.
    NSApplication.shared.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated { path.hasSuffix("/") ? DebugHooks.renderStates(to: path) : DebugHooks.renderIsland(to: path) }
    exit(0)
}
#endif
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
