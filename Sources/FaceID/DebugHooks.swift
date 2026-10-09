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

    /// FACEID_RENDER=<png>: the island's states drawn offscreen with the app's own views, on one picture: scanning,
    /// success, failure, the face setup step (and its end), and the success ring as it tumbles in. Called from main.swift
    /// before the app starts, so nothing shows up on screen.
    static func renderIsland(to path: String) {
        let geometry = IslandGeometry(screen: NSScreen.main)
        func island(_ content: Island.Content, _ view: () -> some View) -> some View {
            let size = geometry.size(for: content)
            return ZStack(alignment: .top) {
                IslandShape(flare: IslandGeometry.flare, radius: content.kind == 0 ? 30 : 34)
                    .fill(Color.black)
                    .frame(width: size.width + 2 * IslandGeometry.flare, height: size.height)
                view()
                    .frame(width: size.width)
                    .padding(.top, geometry.contentTop)
            }
            .frame(width: size.width + 2 * IslandGeometry.flare, height: size.height, alignment: .top)
        }
        func label(_ text: String) -> some View {
            Text(verbatim: text).font(.system(size: 13, weight: .medium)).foregroundColor(.white).fixedSize()
        }
        FaceIDGlyph.debugSuccessTime = 10
        defer { FaceIDGlyph.debugSuccessTime = nil }
        let starting = EnrollModel(purpose: .first)
        let finished = EnrollModel(purpose: .first)
        finished.phase = .finished
        let scans: [(String, GlyphPhase)] = [("Сканирование", .scanning), ("Успех", .success), ("Неудача", .failure)]
        let sheet = VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .top, spacing: 36) {
                ForEach(scans, id: \.0) { name, phase in
                    VStack(spacing: 10) {
                        island(.scan(phase, caption: nil)) {
                            IslandContentView(content: .scan(phase, caption: nil), island: Island.shared)
                        }
                        label(name)
                    }
                }
                VStack(spacing: 10) {
                    island(.ready) { IslandContentView(content: .ready, island: Island.shared) }
                    label("Готово (конец настройки)")
                }
            }
            HStack(alignment: .top, spacing: 36) {
                VStack(spacing: 10) {
                    island(.enroll(starting)) { EnrollView(enroll: starting) }
                    label("Запись лица: начало")
                }
                VStack(spacing: 10) {
                    island(.enroll(finished)) { EnrollView(enroll: finished) }
                    label("Запись лица: готово")
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        ForEach([0.15, 0.35, 0.55, 0.85, 1.2], id: \.self) { time in
                            SuccessRing(time: time, size: 58)
                                .frame(width: 58, height: 58)
                                .padding(10)
                                .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    label("Кольцо успеха: 0,15 · 0,35 · 0,55 · 0,85 · 1,2 с")
                }
            }
        }
        .padding(36)
        .background(Color(white: 0.42))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Drawing the island offscreen: views that ImageRenderer cannot draw (AppKit text fields, the camera preview) show
    /// a stand-in.
    static var offscreen = false

    /// FACEID_RENDER=<folder>/: each state on its own picture at 4x, transparent around the island, which hangs from the
    /// top edge as from the notch, from the first launch to everyday use: the controls before setup, the face setup
    /// (start, a pass in progress, the first pass done, the end), the Mac password, the permissions, setup done, the lock
    /// screen (scan, success, failure), the auto-lock countdown, the controls, the faces, the face check, the settings,
    /// an update on offer, the keychain's confirmation, and the menu bar icon's frames (white, menubar-*.png). A set-up
    /// FaceID is made up in memory: two faces of random numbers, the password and the permissions counted as given;
    /// nothing is saved. The island is as tall as its content, as in the app.
    static func renderStates(to folder: String) {
        let geometry = IslandGeometry(screen: NSScreen.main)
        FaceIDGlyph.debugSuccessTime = 10
        offscreen = true
        defer {
            FaceIDGlyph.debugSuccessTime = nil
            offscreen = false
            UpdateCenter.preview = nil
        }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        func write(_ name: String, _ content: Island.Content, _ view: some View) {
            let flare = IslandGeometry.flare
            let island = view
                .frame(width: geometry.size(for: content).width)
                .padding(.top, geometry.contentTop)
                .padding(.bottom, Island.bottomPadding)
                .background(IslandShape(flare: flare, radius: content.kind == 0 || content.kind == 4 ? 30 : 34)
                    .fill(Color.black)
                    .padding(.horizontal, -flare))
                .padding(.horizontal, flare)
                .environment(\.colorScheme, .dark)
                .environmentObject(AppModel.shared)
                .environmentObject(AppSettings.shared)
            let renderer = ImageRenderer(content: island)
            renderer.scale = 4
            guard let image = renderer.cgImage else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
        func content(_ content: Island.Content) -> some View { IslandContentView(content: content, island: Island.shared) }

        // Before setup: the controls hold only the setup button.
        write("home-setup", .home, HomePage())
        AppModel.shared.setReadyForDebugging(demoEnrollment(faces: 2))

        // The face setup.
        let starting = EnrollModel(purpose: .first)
        let scanning = EnrollModel(purpose: .first)
        scanning.phase = .scanning(pass: 1)
        let covered = (0..<EnrollmentSession.segments).map { [0, 1, 2, 3, 4, 5, 6, 7, 21, 22, 23].contains($0) }
        scanning.progress = EnrollmentSession.Progress(pass: 1, covered: covered, frontal: 4, hint: .turnHead, face: nil,
                                                       imageSize: .zero, direction: CGPoint(x: 18, y: 6))
        let passDone = EnrollModel(purpose: .first)
        passDone.phase = .passDone
        let finished = EnrollModel(purpose: .first)
        finished.phase = .finished
        write("enroll-start", .enroll(starting), EnrollView(enroll: starting))
        write("enroll-scan", .enroll(scanning), EnrollView(enroll: scanning))
        write("enroll-pass", .enroll(passDone), EnrollView(enroll: passDone))
        write("enroll-done", .enroll(finished), EnrollView(enroll: finished))
        let password = PasswordModel()
        write("password", .password(password), PasswordPage(model: password))
        write("access", .access, content(.access))
        write("camera", .camera, content(.camera))
        write("ready", .ready, content(.ready))

        // The lock screen and everyday use.
        write("scan", .scan(.scanning, caption: nil), content(.scan(.scanning, caption: nil)))
        write("success", .scan(.success, caption: nil), content(.scan(.success, caption: nil)))
        write("failure", .scan(.failure, caption: nil), content(.scan(.failure, caption: nil)))
        write("countdown", .countdown(5), content(.countdown(5)))
        write("home", .home, HomePage())
        write("faces", .faces, FacesPage())
        let test = TestModel()
        test.scanResult = .recognized(similarity: 0.8, embedding: [])
        write("test", .test(test), TestView(test: test))
        write("more", .more, MorePage())
        UpdateCenter.preview = .available(Updater.Release(
            version: "1.1.0", title: "FaceID 1.1.0",
            notes: "FaceID разблокирует Mac лицом, как Face ID на iPhone. Когда вы будите заблокированный Mac и смотрите на него, "
                + "у выреза экрана появляется островок и показывает, как идет распознавание. Когда лицо узнано, FaceID вводит пароль, "
                + "а когда вы отходите от Mac, сам его блокирует.",
            page: URL(string: "https://github.com/tihomirov-nick/faceid/releases/tag/v1.1.0")!,
            dmg: URL(string: "https://github.com/tihomirov-nick/faceid/releases/download/v1.1.0/FaceID-1.1.0.dmg")!, size: 11_400_000))
        write("update", .update, UpdatePage())
        UpdateCenter.preview = nil
        write("keychain", .keychain, KeychainPage())

        // The menu bar icon at rest, scanning, with the checkmark and shaking "no": white at 8x.
        let frames: [(String, MenuBarIcon.Frame)] = [("rest", .init()), ("scan", .init(face: 0.45, scan: 0.35)),
                                                     ("check", .init(face: 0, check: 1)), ("shake", .init(shake: -1.5))]
        for (name, frame) in frames {
            let size = MenuBarIcon.size
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 8), pixelsHigh: Int(size.height * 8),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let bounds = NSRect(origin: .zero, size: size)
            MenuBarIcon.image(frame).draw(in: bounds)
            NSColor.white.set()
            bounds.fill(using: .sourceAtop)
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("menubar-\(name).png"))
        }
    }

    /// A face made of random numbers, in memory only.
    private static func demoEnrollment(faces: Int) -> Enrollment {
        let random = { (count: Int) in
            (0..<count).map { _ in
                Enrollment.Template(vector: FaceMatcher.normalized((0..<128).map { _ in Float.random(in: -1...1) }),
                                    yaw: 0, pitch: 0, appearance: 0)
            }
        }
        let enrollment = Enrollment(face: Enrollment.firstName, templates: random(57), openEyes: 0.25)
        return faces == 2 ? enrollment.adding(face: L("Лицо %@", "2"), templates: random(29)) : enrollment
    }

    static func perform(_ action: String) {
        let parts = action.split(separator: "=", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "home": Island.shared.show(.home)
        case "more": Island.shared.show(.more)
        case "faces": Island.shared.show(.faces)
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
            // lock-demo=scanning|success|failure: the lock screen island, in its space above every window (here over the
            // desktop)
            let phase: GlyphPhase = value == "success" ? .success : value == "failure" ? .failure : .scanning
            Island.lockScreen.show(.scan(phase, caption: nil))
        case "lock-flow":
            // A face recognized on the lock screen, over the desktop here: scanning, the green ring, and half a second
            // later the screen "unlocks" and the approval finishes as after a real unlock.
            Island.lockScreen.show(.scan(.scanning, caption: nil))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    let approvedAt = Date()
                    // As UnlockService does when the face is recognized.
                    if Island.lockScreen.aboveLockScreen {
                        Island.lockScreen.show(.scan(.success, caption: nil))
                    } else {
                        Island.lockScreen.hide()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        MainActor.assumeIsolated { AppModel.shared.unlock.playApproval(since: approvedAt) }
                    }
                }
            }
        case "lock-hide": Island.lockScreen.hide()
        case "lock-check":
            // What the lock screen island could disturb: the focused app, secure input, the key window, clicks.
            Log.write("lock check: above the lock screen \(Island.lockScreen.aboveLockScreen) · space "
                + "\(LockScreenSpace.shared?.space.map(String.init) ?? "-") · \(LockScreen.focusDiagnostics) · frontmost "
                + "\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) · FaceID \(getpid()) active \(NSApp.isActive) · "
                + "key window \(NSApp.keyWindow.map { "\($0.windowNumber)" } ?? "-") · a click on the island goes to \(clickTarget())")
        case "setup": Setup.next()
        case "update-demo":
            // update-demo=available|downloading|installing|failed|cannot|offline|checking|uptodate|off: the update
            // interface in that state (nothing is downloaded)
            UpdateCenter.preview = Self.updateState(value)
            UpdateCenter.shared.updater.objectWillChange.send()
            if value != "off", Island.shared.content?.kind != Island.Content.update.kind { Island.shared.show(.update) }
        case "update-state":
            // update-state=<as update-demo>: only the state, for the settings row
            UpdateCenter.preview = Self.updateState(value)
            UpdateCenter.shared.updater.objectWillChange.send()
        case "menubar-sheet":
            // menubar-sheet=<png>: the menu bar icon's frames enlarged and at their real size
            MenuBarIcon.debugSheet(to: value)
        case "menubar":
            // menubar=scanning|success|failure|idle: the menu bar icon's moment
            let moment: MenuBarIcon.Moment = value == "scanning" ? .scanning : value == "success" ? .success : value == "failure" ? .failure : .idle
            StatusItemController.shared.show(moment)
        case "sound":
            // sound=success|failure|start|tick|delete
            if let event = SoundEffects.Event.allCases.first(where: { "\($0)" == value }) { SoundEffects.play(event) }
        case "sounds":
            // Every sound, 1.6 s apart.
            for (index, event) in SoundEffects.Event.allCases.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 1.6) {
                    MainActor.assumeIsolated {
                        Log.write("sound: \(event)")
                        SoundEffects.play(event)
                    }
                }
            }
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
                    Log.write(String(format: "selftest: model OK (%@) · embedding %d",
                                     AppPaths.recognitionModelURL()?.path ?? "-", embedding.count))
                } catch {
                    Log.write("selftest: \(error.localizedDescription)")
                }
            }
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "demo-enrolled":
            // A face made of random numbers (in memory only) to show the "set up" state of the windows.
            AppModel.shared.debugSetEnrollment(demoEnrollment(faces: value == "2" ? 2 : 1))
        default: break
        }
    }

    private static func updateState(_ name: String) -> Updater.State? {
        let release = Updater.Release(
            version: "1.1.0", title: "FaceID 1.1.0",
            notes: "## Что нового\n- Островок со сканированием прямо на экране блокировки\n- Звуки при разблокировке и ошибках\n- Обновление из GitHub",
            page: URL(string: "https://github.com/tihomirov-nick/faceid/releases/tag/v1.1.0")!,
            dmg: URL(string: "https://github.com/tihomirov-nick/faceid/releases/download/v1.1.0/FaceID-1.1.0.dmg")!, size: 11_400_000)
        switch name {
        case "available": return .available(release)
        case "downloading": return .downloading(release, progress: 0.42)
        case "installing": return .installing(release)
        case "failed": return .failed(.notTrusted, release)
        case "cannot": return .failed(.cannotReplace, release)
        case "offline": return .failed(.offline, nil)
        case "checking": return .checking
        case "uptodate": return .upToDate
        default: return nil
        }
    }

    /// The process a click in the middle of the lock screen island would reach, by the Accessibility hit test.
    private static func clickTarget() -> String {
        guard let content = Island.lockScreen.content, let screen = Island.targetScreen(),
              let top = NSScreen.screens.first?.frame.maxY else { return "-" }
        let y = screen.frame.maxY - Island.lockScreen.size(for: content).height / 2
        var element: AXUIElement?
        var pid: pid_t = 0
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(screen.frame.midX), Float(top - y), &element) == .success,
              let element, AXUIElementGetPid(element, &pid) == .success else { return "nothing" }
        return "\(pid)"
    }
}

extension AppModel {
    func debugSetEnrollment(_ enrollment: Enrollment) {
        setEnrollmentForDebugging(enrollment)
    }
}
#endif
