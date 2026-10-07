#if DEBUG
import AppKit
import FaceCore
import SwiftUI

/// Test hooks driven by environment variables (used for automated UI checks), in development builds only:
///   FACEID_ACTIONS="1:home;2:scan-demo;3:dark"    run actions after N seconds (see `perform`)
///   FACEID_SNAPSHOTS="2:/tmp/a.png;4:/tmp/b.png"  save window snapshots after N seconds
///   FACEID_QUIT_AFTER=<seconds>
@MainActor
enum DebugHooks {
    nonisolated static func install() {
        let env = ProcessInfo.processInfo.environment
        // A relaunched copy of the app inherits the environment and must not repeat the test actions.
        for name in ["FACEID_ACTIONS", "FACEID_SNAPSHOTS", "FACEID_QUIT_AFTER"] { unsetenv(name) }
        for (delay, value) in schedule(env["FACEID_ACTIONS"]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { perform(value) } }
        }
        for (delay, value) in schedule(env["FACEID_SNAPSHOTS"]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { snapshot(to: value) } }
        }
        if let quit = env["FACEID_QUIT_AFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + quit) { NSApp.terminate(nil) }
        }
    }

    nonisolated static func schedule(_ text: String?) -> [(Double, String)] {
        (text ?? "").split(separator: ";").compactMap { item in
            let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let delay = Double(parts[0]) else { return nil }
            return (delay, parts[1])
        }
    }

    /// Saves every visible FaceID window, the islands (the first as given, others with a suffix). `screencapture` shows the real
    /// glass; when it is not allowed to record the screen, the view hierarchy is drawn instead (without glass).
    static func snapshot(to path: String) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 60 }
        for (index, window) in windows.enumerated() {
            let suffix = index == 0 ? "" : "-\(index)"
            let url = URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "\(suffix).png"))
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
            try? capture.run()
            capture.waitUntilExit()
            if capture.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) { continue }
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    private static var demoPrompt: SudoPrompt?

    static func perform(_ action: String) {
        let parts = action.split(separator: "=", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "home": Island.shared.show(.home)
        case "more": Island.shared.show(.more)
        case "faces": Island.shared.show(.faces)
        case "disk-access": Island.shared.show(.diskAccess)
        case "password": Island.shared.show(.password(PasswordModel()))
        case "access": Island.shared.show(.access)
        case "ready": Island.shared.show(.ready)
        case "test": TestModel.present()
        case "enroll": EnrollModel.present(value == "add" ? .add : .first)
        case "enroll-demo":
            // enroll-demo=<pass>:<covered segments>|done: the setup island with a fake progress (no camera)
            EnrollModel.presentDemo(value)
        case "island-hide": Island.shared.hide()
        case "lock-demo":
            // lock-demo=scanning|failure: the lock screen island (over the desktop here)
            Island.lockScreen.show(.scan(value == "failure" ? .failure : .scanning, caption: nil))
        case "scan-demo":
            let phase: GlyphPhase = value == "success" ? .success : value == "failure" ? .failure : value == "idle" ? .idle : .scanning
            Island.shared.show(.scan(phase, caption: nil))
        case "countdown-demo": Island.shared.show(.countdown(Int(value) ?? 5))
        case "selftest":
            // selftest=<photo>: loads the models the app ships with and checks one photo; the result goes to the log
            DispatchQueue.global().async {
                do {
                    let engine = try FaceEngine.shared()
                    guard let buffer = PixelBuffers.load(URL(fileURLWithPath: value)),
                          let face = try engine.detector.detect(in: buffer).first else {
                        Log.write("selftest: no face in \(value)")
                        return
                    }
                    let embedding = try engine.embedding(of: buffer, points: face.points)
                    let liveness = engine.liveness(of: buffer, face: face) ?? -1
                    Log.write(String(format: "selftest: models OK (%@) · embedding %d · liveness %.3f",
                                     AppPaths.recognitionModelURL()?.path ?? "-", embedding.count, liveness))
                } catch {
                    Log.write("selftest: \(error.localizedDescription)")
                }
            }
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "sudo-demo":
            // sudo-demo=scanning|recognized|failed: changes the phase of the shown demo prompt, or shows one
            let phase: SudoPrompt.Phase = value == "recognized" ? .recognized
                : value == "failed" ? .failed(ScanHint.notRecognized.message) : .scanning
            if let demoPrompt, Island.shared.showsSudoPrompt {
                demoPrompt.state.phase = phase
            } else {
                let prompt = SudoPrompt(command: "sudo softwareupdate --install --all",
                                        requester: Requester.find(from: getpid()) ?? Requester(name: L("Терминал"), icon: nil),
                                        needsConfirmation: true)
                prompt.state.phase = phase
                prompt.onPassword = { prompt.close() }
                prompt.onAllow = { prompt.close() }
                prompt.show()
                demoPrompt = prompt
            }
        case "demo-enrolled":
            // A face made of random numbers (in memory only) to show the "set up" state of the windows.
            let random = { (count: Int) in
                (0..<count).map { _ in
                    Enrollment.Template(vector: FaceMatcher.normalized((0..<128).map { _ in Float.random(in: -1...1) }),
                                        yaw: 0, pitch: 0, appearance: 0)
                }
            }
            let enrollment = Enrollment(face: Enrollment.firstName, templates: random(57), openEyes: 0.25)
            AppModel.shared.debugSetEnrollment(value == "2" ? enrollment.adding(face: L("Лицо %@", "2"), templates: random(29)) : enrollment)
        default: break
        }
    }
}

extension AppModel {
    func debugSetEnrollment(_ enrollment: Enrollment) {
        setEnrollmentForDebugging(enrollment)
    }
}
#endif
