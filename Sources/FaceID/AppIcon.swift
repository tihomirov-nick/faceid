import AppKit
import FaceCore

/// FaceID's icon in Finder, Launchpad and the lists of macOS. The bundle's own icon (Resources/AppIcon.icon) is black and
/// white, like the icons of the other apps of the family. The classic green one, Resources/AppIconGreen.png (in the
/// bundle, sealed by its signature like the rest), goes on the bundle as its custom icon when the user picks it in the
/// settings: NSWorkspace.setIcon puts an `Icon\r` file into the bundle and the custom icon flag into the Finder info of
/// its folder, as Finder's "Get Info" does. The signature stays as it was: the cdhash, the designated requirement, the
/// updater's check, the keychain and the privacy permissions see no difference. Only `codesign --verify --strict` refuses
/// the bundle while the custom icon is on. Taking it off (`setIcon(nil)`) removes both, and the bundle passes again.
@MainActor
enum AppIcon {
    enum Style: String, CaseIterable {
        case blackAndWhite
        case green

        var title: String {
            switch self {
            case .blackAndWhite: L("Черно-белая")
            case .green: L("Зеленая")
            }
        }
    }

    /// Both icons, for the settings.
    static let previews: [Style: NSImage] = {
        var images: [Style: NSImage] = [:]
        images[.blackAndWhite] = Bundle.main.image(forResource: "AppIcon")
        images[.green] = green
        return images
    }()

    /// The classic green icon: the whole icon as macOS shows one, body and margins included.
    private static var green: NSImage? {
        Bundle.main.url(forResource: "AppIconGreen", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }

    /// The bundle FaceID runs from; nil when it runs as a bare executable (built from the sources), which has no icon.
    nonisolated static var runningBundle: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    /// The user's choice in the settings, put in place at once. When that does not work, the choice stays as it was and
    /// the island says so.
    static func choose(_ style: Style) {
        let settings = AppSettings.shared
        guard style != settings.appIcon else { return }
        if let bundle = runningBundle, put(style, on: bundle) {
            settings.appIcon = style
        } else {
            if runningBundle == nil { Log.write("app icon: not running from an app bundle (\(Bundle.main.bundleURL.path))") }
            AppModel.shared.show(L("Не получилось сменить иконку, попробуйте еще раз"))
        }
    }

    /// At launch: the icon as chosen. An update keeps the custom icon (the updater's FileManager.replaceItemAt carries
    /// it over to the new bundle), but should it get lost, it goes on again; one left from an earlier choice comes off.
    static func restore(on bundle: URL? = runningBundle) {
        guard let bundle else { return }
        let (file, flag) = custom(bundle)
        switch AppSettings.shared.appIcon {
        case .green where !(file && flag):
            Log.write("app icon: the green icon is missing from \(bundle.path), setting it again")
            put(.green, on: bundle)
        case .blackAndWhite where file || flag:
            Log.write("app icon: a custom icon is left on \(bundle.path), taking it off")
            put(.blackAndWhite, on: bundle)
        default:
            break
        }
    }

    /// The custom icon's two parts: the Icon\r file in the bundle and the flag in its folder's Finder info.
    static func custom(_ bundle: URL) -> (file: Bool, flag: Bool) {
        let file = FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Icon\r").path)
        var info = [UInt8](repeating: 0, count: 32)
        let read = getxattr(bundle.path, "com.apple.FinderInfo", &info, info.count, 0, 0)
        // kHasCustomIcon (0x0400) in the Finder flags, the big endian 16 bits at offset 8.
        return (file, read == 32 && info[8] & 0x04 != 0)
    }

    /// Sets the green icon on the bundle or takes the custom icon off, trying twice: NSWorkspace refuses now and then,
    /// and it gives no reason.
    @discardableResult
    static func put(_ style: Style, on bundle: URL) -> Bool {
        var image: NSImage?
        if style == .green {
            guard let green else {
                Log.write("app icon: AppIconGreen.png is missing from \(Bundle.main.bundleURL.path)")
                return false
            }
            image = green
        }
        let what = style == .green ? "set the green icon on" : "take the custom icon off"
        for attempt in 1...2 {
            if NSWorkspace.shared.setIcon(image, forFile: bundle.path, options: []) {
                Log.write("app icon: \(style == .green ? "the green icon is on" : "the custom icon is off") (\(bundle.path))")
                return true
            }
            if attempt == 1 { Log.write("app icon: NSWorkspace did not \(what) \(bundle.path), trying once more") }
        }
        Log.write("app icon: cannot \(what) \(bundle.path): \(obstacle(bundle))")
        return false
    }

    /// Why the bundle could not take the icon, as far as can be told.
    private static func obstacle(_ bundle: URL) -> String {
        if bundle.path.contains("/AppTranslocation/") { return "the app runs translocated (from a disk image or Downloads)" }
        if (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return "its volume is read-only" }
        if !FileManager.default.isWritableFile(atPath: bundle.path) { return "this user may not write to it" }
        return "NSWorkspace.setIcon gave no reason"
    }
}
