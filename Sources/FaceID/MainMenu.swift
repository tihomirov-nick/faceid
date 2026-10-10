import AppKit
import FaceCore

/// What the menu bar icon's menu and the main menu do.
@MainActor
final class AppCommands: NSObject {
    static let shared = AppCommands()

    /// The menu bar icon's menu: FaceID's own action, then the same tail as in every app of the family.
    func statusMenu() -> NSMenu {
        let menu = NSMenu()
        add(L("Заблокировать экран"), #selector(lockScreen), to: menu)
        menu.addItem(.separator())
        add(L("Настройки…"), #selector(showSettings), key: ",", to: menu)
        add(L("Проверить обновления…"), #selector(checkForUpdates), to: menu)
        add(L("О приложении «FaceID»"), #selector(showAbout), to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Завершить FaceID"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    fileprivate func add(_ title: String, _ action: Selector, key: String = "", to menu: NSMenu) {
        menu.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
    }

    @objc func lockScreen() {
        LockScreen.lock()
    }

    /// The settings in the island after Touch ID or the login password, as the "Settings" button of the controls opens them.
    @objc func showSettings() {
        Task { if await AppModel.shared.confirmOwner() { Island.shared.show(.more) } }
    }

    @objc func checkForUpdates() {
        UpdateCenter.shared.checkFromMenu()
    }

    /// The standard About window: the version, the line about FaceID from Info.plist and the license of the face
    /// recognition model FaceID carries.
    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.credits])
    }

    /// The About window's scrolling text: the license of SFace (Resources/LICENSE-sface.txt in the bundle).
    static var credits: NSAttributedString {
        let text = NSMutableAttributedString(string: L("Лицензия модели распознавания лиц SFace"),
                                             attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                          .foregroundColor: NSColor.labelColor])
        if let url = Bundle.main.url(forResource: "LICENSE-sface", withExtension: "txt"),
           let license = try? String(contentsOf: url, encoding: .utf8) {
            text.append(NSAttributedString(string: "\n\n" + license.trimmingCharacters(in: .whitespacesAndNewlines),
                                           attributes: [.font: NSFont.systemFont(ofSize: 9),
                                                        .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return text
    }
}

/// The main menu. FaceID is an agent without menus in the menu bar, so nobody sees it, but it gives the island the
/// standard keys: text fields get ⌘V, ⌘A and ⌘Z only from an Edit menu (the Mac password field), and ⌘, and ⌘Q work while
/// the island has the keyboard.
@MainActor
enum MainMenu {
    static func install() {
        let commands = AppCommands.shared
        let main = NSMenu()

        let appMenu = NSMenu()
        commands.add(L("О приложении «FaceID»"), #selector(AppCommands.showAbout), to: appMenu)
        commands.add(L("Проверить обновления…"), #selector(AppCommands.checkForUpdates), to: appMenu)
        appMenu.addItem(.separator())
        commands.add(L("Настройки…"), #selector(AppCommands.showSettings), key: ",", to: appMenu)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Завершить FaceID"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editMenu = NSMenu(title: L("Правка"))
        // "Отменить" alone is the update page's Cancel.
        editMenu.addItem(withTitle: L("Отменить действие"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L("Повторить действие"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Вырезать"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Скопировать"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Вставить"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Выбрать все"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
