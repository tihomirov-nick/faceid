import AppKit

/// Puts the island above the lock screen. macOS 26 draws the lock screen over every ordinary window, however high its
/// level: a window shows above it only from a space of its own whose absolute level is higher than the lock screen's.
/// SkyLight, the private framework of the window server, makes such spaces (the way github.com/Lakr233/SkyLightWindow
/// does it, MIT). Its functions are looked up at run time; without them the island stays an ordinary window, which
/// macOS shows only after unlocking.
///
/// The space exists only while the island is shown, and the window server removes it by itself if FaceID quits. It holds
/// nothing but the island, which takes neither clicks nor keys: the password field keeps the keyboard and secure input,
/// since both follow the focused app rather than the order of windows on screen.
@MainActor
final class LockScreenSpace {
    /// Nil when this macOS lacks one of the functions.
    static let shared = LockScreenSpace()

    /// Absolute levels of spaces: the lock screen is at 300, Notification Center over the lock screen at 400.
    private static let level: Int32 = 400

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias Create = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias ShowOrHide = @convention(c) (Int32, CFArray) -> Void
    private typealias AddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void
    private typealias Destroy = @convention(c) (Int32, UInt64) -> Void

    private let connection: Int32
    private let create: Create
    private let setLevel: SetLevel
    private let show: ShowOrHide
    private let hide: ShowOrHide
    private let addWindows: AddWindows
    private let destroy: Destroy
    /// The space while the island is in it.
    private(set) var space: UInt64?

    private init?() {
        #if DEBUG
        // FACEID_NO_SKYLIGHT=1: behave as on a macOS without these functions.
        if ProcessInfo.processInfo.environment["FACEID_NO_SKYLIGHT"] != nil { return nil }
        #endif
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        func function<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(sky, name).map { unsafeBitCast($0, to: type) }
        }
        // Only the new space's ID is checked: the other calls return no status (newer systems leave arbitrary values).
        guard let main = function("SLSMainConnectionID", as: MainConnection.self),
              let create = function("SLSSpaceCreate", as: Create.self),
              let setLevel = function("SLSSpaceSetAbsoluteLevel", as: SetLevel.self),
              let show = function("SLSShowSpaces", as: ShowOrHide.self),
              let hide = function("SLSHideSpaces", as: ShowOrHide.self),
              let addWindows = function("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindows.self),
              let destroy = function("SLSSpaceDestroy", as: Destroy.self) else { return nil }
        connection = main()
        self.create = create
        self.setLevel = setLevel
        self.show = show
        self.hide = hide
        self.addWindows = addWindows
        self.destroy = destroy
    }

    /// Moves `window` into the space above the lock screen, making and showing the space first. False when the window
    /// server gave no space.
    func adopt(_ window: NSWindow) -> Bool {
        let space: UInt64
        if let current = self.space {
            space = current
        } else {
            space = create(connection, 1, nil)
            guard space != 0 else { return false }
            setLevel(connection, space, Self.level)
            show(connection, [space] as CFArray)
            self.space = space
        }
        // 7: out of every other space (the current one, the others, the user's), so it is drawn at this level only.
        addWindows(connection, space, [window.windowNumber] as CFArray, 7)
        return true
    }

    /// Hides and destroys the space after its window has been ordered out; the window server puts the window back into
    /// the ordinary spaces.
    func remove() {
        guard let space else { return }
        hide(connection, [space] as CFArray)
        destroy(connection, space)
        self.space = nil
    }
}
