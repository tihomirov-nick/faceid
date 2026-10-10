import XCTest
@testable import FaceCore

/// The interface language of the family standard, on a defaults domain of its own: the app's domain stays untouched.
final class InterfaceLanguageTests: XCTestCase {
    private let suite = "InterfaceLanguageTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    /// The app's own list of languages in the test domain.
    private var ownList: [String]? { defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] }
    private var saved: InterfaceLanguage { InterfaceLanguage.saved(in: defaults, domain: suite) }

    private func save(_ choice: InterfaceLanguage) {
        InterfaceLanguage.save(choice, in: defaults, domain: suite)
    }

    // MARK: Same as System

    func testSameAsSystemTakesTheFirstLanguageTheAppSpeaks() {
        XCTAssertEqual(InterfaceLanguage.language(for: ["en-US", "ru-US"]), "en")
        XCTAssertEqual(InterfaceLanguage.language(for: ["ru-RU", "en"]), "ru")
        XCTAssertEqual(InterfaceLanguage.language(for: ["de-DE", "ru-RU"]), "ru")
        XCTAssertEqual(InterfaceLanguage.language(for: ["de-DE"]), "en")
        XCTAssertEqual(InterfaceLanguage.language(for: []), "en")
    }

    // MARK: The choice

    func testEachChoiceIsTheAppsOwnLanguageList() {
        XCTAssertEqual(saved, .system)
        save(.russian)
        XCTAssertEqual(ownList, ["ru"])
        XCTAssertEqual(saved, .russian)
        save(.english)
        XCTAssertEqual(ownList, ["en"])
        XCTAssertEqual(saved, .english)
        save(.system)
        XCTAssertNil(ownList)
        XCTAssertEqual(saved, .system)
    }

    func testAChoiceMadeInSystemSettingsIsTheSameChoice() {
        defaults.set(["ru-RU"], forKey: "AppleLanguages")
        XCTAssertEqual(saved, .russian)
        defaults.set(["en-GB", "ru"], forKey: "AppleLanguages")
        XCTAssertEqual(saved, .english)
    }

    func testAForeignLanguageInTheListShowsAsSameAsSystem() {
        defaults.set(["de"], forKey: "AppleLanguages")
        XCTAssertEqual(saved, .system)
        // macOS falls back to English from it, whatever the Mac's languages are.
        XCTAssertEqual(InterfaceLanguage.nextLaunch(in: defaults, domain: suite, systemLanguages: ["ru-RU"]), "en")
        XCTAssertFalse(InterfaceLanguage.needsRestart(running: "en", in: defaults, domain: suite, systemLanguages: ["ru-RU"]))
        // Picking "Same as System" for real removes it.
        save(.system)
        XCTAssertNil(ownList)
        XCTAssertTrue(InterfaceLanguage.needsRestart(running: "en", in: defaults, domain: suite, systemLanguages: ["ru-RU"]))
    }

    func testNothingIsWrittenWithoutADomainOfItsOwn() {
        InterfaceLanguage.save(.russian, in: defaults, domain: nil)
        XCTAssertNil(ownList)
        XCTAssertEqual(InterfaceLanguage.saved(in: defaults, domain: nil), .system)
    }

    // MARK: Restart

    func testRestartIsNeededWhenTheNextLaunchSpeaksAnotherLanguage() {
        let mac = ["en-US", "ru-US"]
        func needsRestart(_ running: String) -> Bool {
            InterfaceLanguage.needsRestart(running: running, in: defaults, domain: suite, systemLanguages: mac)
        }
        XCTAssertFalse(needsRestart("en"))
        XCTAssertTrue(needsRestart("ru"))
        save(.russian)
        XCTAssertTrue(needsRestart("en"))
        XCTAssertFalse(needsRestart("ru"))
        save(.english)
        XCTAssertFalse(needsRestart("en"))
        save(.system)
        XCTAssertFalse(needsRestart("en"))
        XCTAssertEqual(InterfaceLanguage.nextLaunch(in: defaults, domain: suite, systemLanguages: ["de-DE", "ru-RU"]), "ru")
        // A process without a domain of its own saves nothing, so a restart would change nothing.
        XCTAssertFalse(InterfaceLanguage.needsRestart(running: "ru", in: defaults, domain: nil, systemLanguages: mac))
    }

    /// The helper waits for the app to quit, then opens it by its place, or by its id when nothing is left there.
    /// `/bin/echo` stands in for `open`; the app is a `sleep` that launchd reaps, as it reaps a quitting app.
    func testRestartHelperWaitsForTheAppToQuitAndOpensItAgain() throws {
        let place = FileManager.default.temporaryDirectory
        let started = Date()
        XCTAssertEqual(try runHelper(pid: try detachedSleep(0.5), app: place, bundleID: "com.example.app"), place.path)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.3)
        let gone = place.appendingPathComponent("Gone \(UUID().uuidString).app")
        XCTAssertEqual(try runHelper(pid: try detachedSleep(0.1), app: gone, bundleID: "com.example.app"), "-b com.example.app")
    }

    private func detachedSleep(_ seconds: Double) throws -> Int32 {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep \(seconds) >/dev/null 2>&1 & echo $!"]
        let output = Pipe()
        shell.standardOutput = output
        try shell.run()
        shell.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return try XCTUnwrap(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func runHelper(pid: Int32, app: URL, bundleID: String) throws -> String {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = InterfaceLanguage.relaunchArguments(pid: pid, app: app, bundleID: bundleID, open: "/bin/echo")
        let output = Pipe()
        helper.standardOutput = output
        try helper.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        helper.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Earlier settings (the keys of Screenshooter 1.2)

    private func migrate(choice: String?, applied: String?, list: [String]?) {
        if let choice { defaults.set(choice, forKey: "ScreenshooterLanguage") }
        if let applied { defaults.set(applied, forKey: "ScreenshooterAppliedLanguage") }
        if let list { defaults.set(list, forKey: "AppleLanguages") }
        InterfaceLanguage.migrate(choiceKey: "ScreenshooterLanguage", appliedKey: "ScreenshooterAppliedLanguage",
                                  in: defaults, domain: suite)
        let values = defaults.persistentDomain(forName: suite) ?? [:]
        XCTAssertNil(values["ScreenshooterLanguage"])
        XCTAssertNil(values["ScreenshooterAppliedLanguage"])
    }

    func testMigrationDropsTheListWrittenForAutomatic() {
        migrate(choice: "automatic", applied: "ru", list: ["ru"])
        XCTAssertNil(ownList)
        XCTAssertEqual(saved, .system)
    }

    func testMigrationDropsTheListWrittenWithoutAChoice() {
        migrate(choice: nil, applied: "en", list: ["en"])
        XCTAssertNil(ownList)
    }

    func testMigrationKeepsALanguagePickedByHand() {
        migrate(choice: "ru", applied: "ru", list: ["ru"])
        XCTAssertEqual(ownList, ["ru"])
        XCTAssertEqual(saved, .russian)
    }

    func testMigrationWritesAPickedLanguageTheAppNeverApplied() {
        migrate(choice: "en", applied: nil, list: nil)
        XCTAssertEqual(ownList, ["en"])
    }

    func testMigrationKeepsAChoiceMadeLaterInSystemSettings() {
        migrate(choice: "automatic", applied: "ru", list: ["en"])
        XCTAssertEqual(ownList, ["en"])
        defaults.removePersistentDomain(forName: suite)
        // "System Language" in System Settings removed the list after Russian was picked in the app.
        migrate(choice: "ru", applied: "ru", list: nil)
        XCTAssertNil(ownList)
    }

    func testMigrationLeavesAnAppWithoutEarlierKeysAlone() {
        defaults.set(["en"], forKey: "AppleLanguages")
        defaults.set(true, forKey: "Other")
        InterfaceLanguage.migrate(choiceKey: "ScreenshooterLanguage", appliedKey: "ScreenshooterAppliedLanguage",
                                  in: defaults, domain: suite)
        XCTAssertEqual(ownList, ["en"])
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["Other"] as? Bool, true)
    }
}
