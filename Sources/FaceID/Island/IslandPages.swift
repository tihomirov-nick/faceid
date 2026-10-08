import AppKit
import FaceCore
import SwiftUI

// MARK: - Setup

/// First setup goes step by step in the island, each step a single action: the face, the login password,
/// permission to type it, then a checkmark. Steps already done are skipped.
@MainActor
enum Setup {
    static func next() {
        let model = AppModel.shared
        model.refresh()
        if !model.isEnrolled {
            EnrollModel.present(.first)
        } else if !model.passwordSaved {
            Island.shared.show(.password(PasswordModel()))
        } else if !model.accessibilityTrusted {
            Island.shared.show(.access)
            AccessWatcher.start()
        } else {
            model.settings.unlockEnabled = true
            if !model.launchAtLogin { model.setLaunchAtLogin(true) }
            Haptics.success()
            Island.shared.show(.ready)
            Island.shared.hide(after: 1.6)
        }
    }
}

/// Waits for the Accessibility permission to be granted in System Settings, then goes on with the setup.
@MainActor
enum AccessWatcher {
    private static var timer: Timer?

    static func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard case .access = Island.shared.content else {
                    timer?.invalidate()
                    timer = nil
                    return
                }
                guard LockScreen.canType else { return }
                timer?.invalidate()
                timer = nil
                NSApp.activate(ignoringOtherApps: true)
                Setup.next()
            }
        }
    }
}

// MARK: - Home

/// The controls, laid out like Control Center on the Mac: four switches as pills with an icon and a one-line name,
/// two by two, and three buttons. Pointing at a switch tells what it does. Before setup there is only the setup
/// button.
struct HomePage: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var settings = AppSettings.shared

    enum Control {
        case unlock, autoLock, attention, blink
    }

    var body: some View {
        if model.isEnrolled {
            VStack(spacing: 8) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    Tile(symbol: "lock.open.fill", title: L("Разблокировка"), on: settings.unlockEnabled && model.canUnlock,
                         attention: !model.canUnlock || model.passwordProblem, control: .unlock) {
                        if !model.canUnlock || model.passwordProblem {
                            if model.passwordProblem { model.forgetPassword() }
                            Setup.next()
                        } else {
                            settings.unlockEnabled.toggle()
                        }
                    }
                    Tile(symbol: "figure.walk.departure", title: L("Автоблокировка"), on: settings.autoLockEnabled,
                         control: .autoLock) {
                        settings.autoLockEnabled.toggle()
                    }
                    Tile(symbol: "eye.fill", title: L("Внимание"), on: settings.requireAttention,
                         control: .attention) {
                        weaken(settings.requireAttention) { settings.requireAttention.toggle() }
                    }
                    Tile(symbol: "eye.slash.fill", title: L("Моргание"), on: settings.requireBlink,
                         control: .blink) {
                        weaken(settings.requireBlink) { settings.requireBlink.toggle() }
                    }
                }
                if let message = model.message {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    Button(L("Проверить")) { TestModel.present() }
                        .appButton(.primary)
                    Button(L("Лица")) { Island.shared.show(.faces) }
                        .appButton(.secondary)
                    Button(L("Еще")) {
                        Task { if await model.confirmOwner() { Island.shared.show(.more) } }
                    }
                    .appButton(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .animation(.easeInOut(duration: 0.2), value: model.message)
        } else {
            VStack(spacing: 12) {
                FaceIDGlyph(phase: .idle, size: 46, color: FaceIDGlyph.green)
                Button(L("Настроить FaceID")) { Setup.next() }
                    .appButton(.primary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
    }

    /// What a switch does, for its tooltip.
    static func help(_ control: Control) -> String {
        let model = AppModel.shared
        switch control {
        case .unlock:
            if model.passwordProblem { return L("Пароль от Mac не подошел. Нажмите, чтобы ввести новый") }
            if !model.canUnlock { return L("Для разблокировки не хватает пароля от Mac или разрешения. Нажмите, чтобы закончить настройку") }
            return L("Mac разблокируется, когда вы на него смотрите")
        case .autoLock:
            return L("Mac блокируется сам, когда вы от него отходите")
        case .attention:
            return L("FaceID узнает вас, только если вы смотрите на экран с открытыми глазами")
        case .blink:
            return L("Перед разблокировкой нужно моргнуть, на фото этого не сделать")
        }
    }

    /// Turning a protection off needs the owner; turning it on does not.
    private func weaken(_ on: Bool, _ change: @escaping () -> Void) {
        guard on else { return change() }
        Task { if await model.confirmOwner() { change() } }
    }
}

/// A switch as in Control Center: a wide pill with an icon circle (green when on) and the name on one line.
/// It sinks when pressed and springs back, the icon bounces and a ring spreads out when it changes, the trackpad
/// taps. An orange dot when it needs something before it can work.
struct Tile: View {
    let symbol: String
    let title: String
    let on: Bool
    var attention = false
    let control: HomePage.Control
    let action: () -> Void
    @State private var hovering = false
    @State private var ripples = 0
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: symbol)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, value: on)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(on ? Brand.green : Color.white.opacity(0.16)))
                        .background {
                            // The ring that spreads out when the switch changes.
                            Circle()
                                .stroke(on ? Brand.green : Color.white, lineWidth: 2)
                                .keyframeAnimator(initialValue: Ripple(), trigger: ripples) { view, ripple in
                                    view.scaleEffect(ripple.scale).opacity(ripple.opacity)
                                } keyframes: { _ in
                                    KeyframeTrack(\.opacity) {
                                        LinearKeyframe(0.8, duration: 0.01)
                                        LinearKeyframe(0, duration: 0.45)
                                    }
                                    KeyframeTrack(\.scale) {
                                        LinearKeyframe(1, duration: 0.01)
                                        CubicKeyframe(1.6, duration: 0.45)
                                    }
                                }
                        }
                    if attention {
                        Circle().fill(Color.orange).frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                            .offset(x: 2, y: -2)
                    }
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(hovering ? 0.13 : 0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(TilePressStyle())
        .onHover { hovering = $0 }
        .help(HomePage.help(control))
        .onChange(of: on) { _, _ in
            ripples += 1
            Haptics.tap()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(title)
        .accessibilityValue(on ? L("Вкл") : L("Выкл"))
    }

    private struct Ripple {
        var scale: CGFloat = 1
        var opacity: Double = 0
    }
}

/// Sinks when pressed, springs back with a little bounce.
private struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(configuration.isPressed ? .spring(response: 0.18, dampingFraction: 0.8)
                                               : .spring(response: 0.35, dampingFraction: 0.45),
                       value: configuration.isPressed)
    }
}

// MARK: - Faces

/// The enrolled faces: rename (click the name), record again, delete; add another one.
struct FacesPage: View {
    @ObservedObject private var model = AppModel.shared
    @State private var editing: Int?
    @State private var name = ""
    @State private var deleting: Int?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            // While a name is being edited, Escape cancels the edit instead of leaving the page.
            PageHeader(title: L("Лица"), escapeGoesBack: editing == nil)
            VStack(spacing: 0) {
                ForEach(Array((model.enrollment?.faces ?? []).enumerated()), id: \.element.id) { index, face in
                    row(face)
                    if index < (model.enrollment?.faces.count ?? 0) - 1 {
                        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.leading, 40)
                    }
                }
            }
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button {
                EnrollModel.present(.add)
            } label: {
                Label(L("Добавить лицо"), systemImage: "plus")
            }
            .appButton(.secondary)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .foregroundStyle(.white)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: deleting)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.enrollment?.faces)
    }

    private func row(_ face: Enrollment.Face) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "faceid")
                .font(.system(size: 16, weight: .light))
                .frame(width: 20)
            if editing == face.id {
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.12)))
                    .focused($nameFocused)
                    .onSubmit { rename(face) }
                    .onExitCommand { editing = nil }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused, editing == face.id { rename(face) }
                    }
                    .onAppear {
                        // Typing needs FaceID to be the active app.
                        NSApp.activate(ignoringOtherApps: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { nameFocused = true }
                    }
            } else {
                NameButton(name: face.name) {
                    name = face.name
                    editing = face.id
                }
            }
            Spacer(minLength: 6)
            Text(pluralize(model.enrollment?.shots(of: face.id) ?? 0, "снимок", "снимка", "снимков", en: "shot", "shots"))
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            if deleting == face.id {
                Button(L("Удалить")) {
                    deleting = nil
                    Task { if await model.confirmOwner() { model.removeFace(face.id) } }
                }
                .appButton(.destructive)
                .controlSize(.mini)
            } else {
                IconButton(symbol: "arrow.counterclockwise", help: L("Записать заново")) {
                    EnrollModel.present(.redo(face.id))
                }
                IconButton(symbol: "trash", help: L("Удалить")) { deleting = face.id }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    private func rename(_ face: Enrollment.Face) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != face.name { model.renameFace(face.id, to: trimmed) }
        editing = nil
    }
}

/// A face's name: a click starts renaming; a pencil shows that it can.
private struct NameButton: View {
    let name: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .opacity(hovering ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(L("Переименовать"))
    }
}

/// A small round button with an SF Symbol.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(TilePressStyle())
        .help(help)
    }
}

/// Back to the controls (also Escape), and the page title.
struct PageHeader: View {
    let title: String
    var escapeGoesBack = true

    var body: some View {
        ZStack {
            Text(title).font(.system(size: 13, weight: .semibold))
            HStack {
                if escapeGoesBack {
                    back.keyboardShortcut(.cancelAction)
                } else {
                    back
                }
                Spacer()
            }
        }
    }

    private var back: some View {
        IconButton(symbol: "chevron.left", help: L("Назад")) { Island.shared.show(.home) }
    }
}

// MARK: - More

/// The other settings, one short row each.
struct MorePage: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 8) {
            PageHeader(title: L("Настройки"))
            VStack(spacing: 0) {
                Row(title: L("Строгость")) {
                    Segments(selection: $settings.strictness, options: Strictness.allCases.map { ($0, $0.title) })
                }
                Row(title: L("Автоблокировка")) {
                    Segments(selection: $settings.autoLockDelay,
                             options: [(15, L("15 с")), (30, L("30 с")), (60, L("1 мин")), (120, L("2 мин")), (300, L("5 мин"))])
                }
                Row(title: L("Анимация разблокировки")) { Switch(isOn: $settings.lockScreenBadge) }
                Row(title: L("Внешние камеры")) { Switch(isOn: $settings.allowExternalCamera) }
                Row(title: L("Запускать при входе"), last: true) {
                    Switch(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                }
            }
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 6) {
                Button(L("Сменить пароль")) {
                    model.forgetPassword()
                    Island.shared.show(.password(PasswordModel()))
                }
                .appButton(.secondary)
                Button(L("Журнал")) { NSWorkspace.shared.open(Log.fileURL) }
                    .appButton(.secondary)
                Button(L("Выйти")) { NSApp.terminate(nil) }
                    .appButton(.secondary)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .foregroundStyle(.white)
    }

    private struct Row<Control: View>: View {
        let title: String
        var last = false
        @ViewBuilder let control: Control

        var body: some View {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 6)
                control
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .overlay(alignment: .bottom) {
                if !last { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.leading, 12) }
            }
        }
    }
}

/// A switch drawn by the app, as on iPhone: green when on, the knob stretches while pressed and slides with a spring.
struct Switch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
            Haptics.tap()
        } label: {
            EmptyView()
        }
        .buttonStyle(SwitchStyle(isOn: isOn))
        .accessibilityValue(isOn ? L("Вкл") : L("Выкл"))
    }

    private struct SwitchStyle: ButtonStyle {
        let isOn: Bool

        func makeBody(configuration: Configuration) -> some View {
            let pressed = configuration.isPressed
            Capsule()
                .fill(isOn ? Brand.green : Color.white.opacity(0.22))
                .frame(width: 36, height: 21)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(.white)
                        .frame(width: pressed ? 22 : 17, height: 17)
                        .padding(2)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
                .contentShape(Capsule())
                .animation(.spring(response: 0.3, dampingFraction: 0.68), value: isOn)
                .animation(.spring(response: 0.22, dampingFraction: 0.75), value: pressed)
        }
    }
}

/// A choice drawn by the app: the white pill slides to the chosen option.
struct Segments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options, id: \.0) { value, title in
                Button {
                    selection = value
                    Haptics.tap()
                } label: {
                    Text(title)
                        .font(.system(size: 10.5, weight: selection == value ? .semibold : .regular))
                        .foregroundStyle(selection == value ? Color.black : Color.white.opacity(0.8))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background {
                            if selection == value {
                                Capsule().fill(Color.white).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(TilePressStyle())
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.12)))
        .animation(.spring(response: 0.32, dampingFraction: 0.75), value: selection)
    }
}

// MARK: - Password

@MainActor
final class PasswordModel: ObservableObject {
    @Published var password = ""
    @Published var checking = false
    @Published var wrong = 0

    func save() {
        guard !password.isEmpty, !checking else { return }
        checking = true
        Task {
            let saved = await AppModel.shared.savePassword(password)
            checking = false
            if saved {
                password = ""
                Setup.next()
            } else {
                Haptics.failure()
                wrong += 1
            }
        }
    }
}

/// The login password, one field: FaceID types it on the lock screen.
struct PasswordPage: View {
    @ObservedObject var model: PasswordModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                SecureField(L("Пароль Mac"), text: $model.password)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .focused($focused)
                    .onSubmit { model.save() }
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Capsule().fill(Color.white.opacity(0.12)))
            .overlay(Capsule().stroke(model.wrong > 0 ? Color.red.opacity(0.8) : .clear, lineWidth: 1.5))
            .keyframeAnimator(initialValue: 0.0, trigger: model.wrong) { view, offset in
                view.offset(x: offset)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(0, duration: 0.01)
                    SpringKeyframe(-10, duration: 0.08)
                    SpringKeyframe(10, duration: 0.1)
                    SpringKeyframe(-6, duration: 0.1)
                    SpringKeyframe(0, duration: 0.12)
                }
            }
            HStack(spacing: 10) {
                Button(L("Позже")) { Island.shared.hide() }
                    .appButton(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button(model.checking ? L("Проверяю…") : L("Готово")) { model.save() }
                    .appButton(.primary)
                    .disabled(model.password.isEmpty || model.checking)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .onAppear {
            // Typing needs FaceID to be the active app.
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true }
        }
    }
}

// MARK: - Accessibility

/// Permission to type the password on the lock screen: one button; the island moves on by itself once it is given.
struct AccessPage: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "accessibility")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.white)
            HStack(spacing: 8) {
                Button(L("Позже")) { Island.shared.hide() }
                    .appButton(.secondary)
                Button(L("Разрешить")) { AppModel.shared.requestAccessibility() }
                    .appButton(.primary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.top, 12)
    }
}

// MARK: - Opening the island

/// A click on the notch opens the controls: an invisible window over the notch catches it.
@MainActor
final class NotchHotspot {
    private var panel: NSPanel?

    func install() {
        update()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.update() }
        }
    }

    private func update() {
        guard let screen = NSScreen.screens.first(where: { $0.notch != nil }), let notch = screen.notch else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(NSRect(x: screen.frame.midX - notch.width / 2, y: screen.frame.maxY - notch.height,
                              width: notch.width, height: notch.height), display: false)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        // Not fully transparent: windows let clicks through where nothing is drawn. Over the notch it is invisible.
        panel.backgroundColor = NSColor(white: 0, alpha: 0.01)
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = ClickView { Island.shared.toggleHome() }
        return panel
    }

    private final class ClickView: NSView {
        let action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            MainActor.assumeIsolated { action() }
        }
    }
}

/// The Face ID glyph in the menu bar: a click opens the controls in the island, a right click offers Quit.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    override init() {
        super.init()
        item.button?.image = .faceGlyph()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: L("Заблокировать экран"), action: #selector(lockScreen), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: L("Выйти из FaceID"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            Island.shared.toggleHome()
        }
    }

    @objc private func lockScreen() {
        LockScreen.lock()
    }
}
