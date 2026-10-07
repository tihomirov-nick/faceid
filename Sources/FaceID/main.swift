import AppKit
import FaceCore

// FaceID has no windows of its own: it lives in the menu bar and in the island under the notch.
Localization.apply()
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
