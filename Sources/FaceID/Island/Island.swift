import AppKit
import FaceCore
import SwiftUI

/// FaceID lives in the notch, like Face ID in the iPhone's Dynamic Island: scans, face setup, the controls and the
/// auto-lock countdown grow out of the notch as a black island and shrink back into it. On a display without
/// a notch (older Macs, external displays) the same island slides down from the top edge of the screen.
@MainActor
final class Island: ObservableObject {
    /// The island over the desktop.
    static let shared = Island(lockScreen: false)
    /// The island over the lock screen: only the scan, in a window of its own above the lock screen (`LockScreenSpace`)
    /// that never takes clicks or keys.
    static let lockScreen = Island(lockScreen: true)

    enum Content {
        /// The Face ID glyph alone (the lock screen, the approval after unlocking).
        case scan(GlyphPhase, caption: String?)
        case enroll(EnrollModel)
        case test(TestModel)
        /// Seconds left before the auto-lock.
        case countdown(Int)
        /// The controls: what FaceID is used for (or the setup button).
        case home
        case more
        case faces
        case password(PasswordModel)
        case access
        case camera
        /// The keychain wants the user's confirmation before FaceID may read the face and the password again.
        case keychain
        /// A new version of FaceID, its download and install.
        case update
        /// Setup finished.
        case ready

        var kind: Int {
            switch self {
            case .scan: 0
            case .enroll: 2
            case .test: 3
            case .countdown: 4
            case .home: 5
            case .more: 6
            case .password: 7
            case .access: 8
            case .ready: 9
            case .faces: 10
            case .keychain: 11
            case .camera: 12
            case .update: 13
            }
        }

        /// Plain values rather than a model object.
        var isValue: Bool {
            switch self {
            case .scan, .countdown, .home, .more, .faces, .access, .camera, .keychain, .update, .ready: true
            case .enroll, .test, .password: false
            }
        }

        /// Takes clicks and keys (buttons inside).
        var interactive: Bool {
            switch self {
            case .enroll, .test, .home, .more, .faces, .password, .access, .camera, .keychain, .update: true
            case .scan, .countdown, .ready: false
            }
        }

        /// Takes the keyboard as it comes out. An update offer comes by itself, so it waits for a click: the app in front
        /// keeps the keys meanwhile.
        var takesKeyboard: Bool {
            if case .update = self { return false }
            return interactive
        }

        /// Closes when the user clicks elsewhere, as the Dynamic Island does.
        var closesOnOutsideClick: Bool {
            switch self {
            case .home, .more, .faces, .test, .password, .access, .camera, .keychain, .update: true
            default: false
            }
        }
    }

    @Published private(set) var content: Content?
    @Published private(set) var expanded = false
    @Published private(set) var geometry = IslandGeometry(screen: nil)
    /// Changes whenever the content changes, so SwiftUI animates between contents of the same kind too.
    @Published private(set) var revision = 0

    let isLockScreen: Bool
    /// The island over the lock screen is in the space above it, so macOS shows it there (and over everything after
    /// unlocking, until it goes back into the notch).
    private(set) var aboveLockScreen = false
    /// Heights the contents turned out to need, by content kind (measured each time they lay out).
    @Published private(set) var measuredHeights: [Int: CGFloat] = [:]
    /// The same space under every content.
    static let bottomPadding: CGFloat = 14
    private var panel: IslandPanel?
    private var hideWork: DispatchWorkItem?
    /// Called when the island closes by itself or is replaced (the owner of the content cleans up).
    private var onClose: (() -> Void)?

    private init(lockScreen: Bool) {
        isLockScreen = lockScreen
    }

    var isShowing: Bool { content != nil }

    /// Shows `content`, growing out of the notch (or morphing from what is shown now).
    func show(_ content: Content, onClose: (() -> Void)? = nil) {
        hideWork?.cancel()
        hideWork = nil
        let replacing = self.content.map { !($0.kind == content.kind && (content.isValue || sameObject($0, content))) } ?? false
        if replacing, let previous = self.onClose {
            self.onClose = nil
            previous()
        }
        if onClose != nil || replacing { self.onClose = onClose }
        let screen = Self.targetScreen()
        let geometry = IslandGeometry(screen: screen)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let wasHidden = !panel.isVisible || self.content == nil
        // The window is as large as the island will become; the shape animates inside it.
        let size = self.size(for: content, in: geometry)
        let frameSize = NSSize(width: max(size.width + 2 * IslandGeometry.flare + 60, wasHidden ? 0 : panel.frame.width),
                               height: max(size.height + 40, wasHidden ? 0 : panel.frame.height))
        if let screen {
            panel.setFrame(NSRect(x: screen.frame.midX - frameSize.width / 2, y: screen.frame.maxY - frameSize.height,
                                  width: frameSize.width, height: frameSize.height), display: false)
        }
        // The island over the lock screen lets every click and key through to the password field below.
        panel.interactive = content.interactive && !isLockScreen
        panel.ignoresMouseEvents = !panel.interactive
        self.geometry = geometry
        // After the content below has changed (both run when show returns).
        defer {
            updateClickMonitors()
            fitFrame(after: 0.5)
        }
        if wasHidden {
            expanded = false
            self.content = content
            revision += 1
            if panel.interactive && content.takesKeyboard {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }
            if isLockScreen {
                aboveLockScreen = LockScreenSpace.shared?.adopt(panel) ?? false
            }
            DispatchQueue.main.async {
                withAnimation(IslandGeometry.spring) { self.expanded = true }
            }
        } else {
            // The same kind of content keeps its views (a glyph morphs from scanning to the checkmark, a countdown
            // just changes its number); a different kind replaces them with a transition.
            let keep = self.content.map { $0.kind == content.kind && (content.isValue || sameObject($0, content)) } ?? false
            withAnimation(IslandGeometry.spring) {
                self.content = content
                if !keep { self.revision += 1 }
                self.expanded = true
            }
            if panel.interactive && content.takesKeyboard { panel.makeKey() }
        }
    }

    /// While the island morphs the window keeps the larger of the old and new sizes; afterwards it shrinks to the
    /// content, so that the empty part of the window does not cover the menu bar or windows below.
    private func fitFrame(after delay: TimeInterval) {
        let revision = self.revision
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.revision == revision, let content = self.content, let panel = self.panel,
                      let screen = Self.targetScreen() else { return }
                let size = self.size(for: content)
                let frame = NSSize(width: size.width + 2 * IslandGeometry.flare + 60, height: size.height + 40)
                panel.setFrame(NSRect(x: screen.frame.midX - frame.width / 2, y: screen.frame.maxY - frame.height,
                                      width: frame.width, height: frame.height), display: true)
            }
        }
    }

    /// Opens the controls, or closes them when they are open (the menu bar icon and a click on the notch).
    func toggleHome() {
        if case .home = content {
            hide()
            return
        }
        if case .enroll = content { return }
        AppModel.shared.refresh()
        show(.home)
    }

    private var clickMonitors: [Any] = []
    /// A system dialog (Touch ID) is up for something in the island: clicks in it must not close the island.
    var keepOpen = false

    /// Watches for clicks outside the island while it shows something that should close like a popover.
    private func updateClickMonitors() {
        let wanted = content?.closesOnOutsideClick ?? false
        guard wanted != !clickMonitors.isEmpty else { return }
        if wanted {
            let outside: (NSEvent) -> Void = { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.keepOpen, let panel = self.panel, self.content?.closesOnOutsideClick == true else { return }
                    let shape = self.islandFrame(in: panel)
                    if !shape.contains(NSEvent.mouseLocation) { self.hide() }
                }
            }
            if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: outside) {
                clickMonitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in
                outside(event)
                return event
            }) {
                clickMonitors.append(local)
            }
        } else {
            clickMonitors.forEach(NSEvent.removeMonitor)
            clickMonitors.removeAll()
        }
    }

    /// The island's shape in screen coordinates (the window around it is larger).
    private func islandFrame(in panel: NSPanel) -> NSRect {
        guard let content else { return .zero }
        let size = self.size(for: content)
        let frame = panel.frame
        return NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
    }

    /// The island for `content`: its width, and the height its content measured plus the bottom padding (the estimate
    /// from `IslandGeometry` until it has been laid out once).
    func size(for content: Content, in geometry: IslandGeometry? = nil) -> CGSize {
        let geometry = geometry ?? self.geometry
        let estimate = geometry.size(for: content)
        guard let measured = measuredHeights[content.kind] else { return estimate }
        return CGSize(width: estimate.width, height: geometry.contentTop + measured + Self.bottomPadding)
    }

    /// The content laid out at `height`: the island follows (and the window grows first if it would be too small).
    func measured(_ height: CGFloat, for kind: Int) {
        guard height > 0, abs((measuredHeights[kind] ?? 0) - height) > 0.5 else { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["FACEID_PRINT_HEIGHTS"] != nil {
            FileHandle.standardError.write(Data("island content \(kind): \(height)\n".utf8))
        }
        #endif
        withAnimation(IslandGeometry.spring) { measuredHeights[kind] = height }
        guard let panel, let content, content.kind == kind, let screen = Self.targetScreen() else { return }
        let needed = size(for: content).height + 40
        if panel.frame.height < needed {
            let width = panel.frame.width
            panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - needed, width: width, height: needed),
                           display: true)
        } else {
            fitFrame(after: 0.5)
        }
    }

    /// Shrinks the island back into the notch and removes it.
    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.collapse() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func collapse() {
        guard content != nil else { return }
        let close = onClose
        onClose = nil
        close?()
        withAnimation(IslandGeometry.spring) { expanded = false }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.expanded else { return }
                self.panel?.orderOut(nil)
                self.content = nil
                self.updateClickMonitors()
                if self.isLockScreen {
                    // No empty layer is left above the lock screen or the desktop.
                    LockScreenSpace.shared?.remove()
                    self.aboveLockScreen = false
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    /// The display with the notch (the camera is above it), otherwise the one with the key window.
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.notch != nil } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func sameObject(_ a: Content, _ b: Content) -> Bool {
        switch (a, b) {
        case let (.enroll(x), .enroll(y)): x === y
        case let (.test(x), .test(y)): x === y
        default: false
        }
    }

    private func makePanel() -> IslandPanel {
        let panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        if isLockScreen {
            // Allowed while the screen is locked; the space above the lock screen (`LockScreenSpace`) makes it seen there.
            panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            panel.canBecomeVisibleWithoutLogin = true
        } else {
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        }
        let host = NSHostingView(rootView: IslandView(island: self))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }
}

/// A borderless panel at the top of the screen that may take keys without activating FaceID: Return and Escape
/// reach the island while the app in front stays active.
final class IslandPanel: NSPanel {
    var interactive = false

    override var canBecomeKey: Bool { interactive }
    override var canBecomeMain: Bool { false }

    /// Windows are normally kept below the menu bar; the island has to sit on top of it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

extension NSScreen {
    /// The camera notch, if the display has one: its size in points.
    var notch: CGSize? {
        guard safeAreaInsets.top > 0, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        let width = frame.width - left.width - right.width
        return width > 0 ? CGSize(width: width, height: safeAreaInsets.top) : nil
    }
}

/// Island sizes on a given display.
struct IslandGeometry: Equatable {
    /// The notch, or nil on displays without one.
    let notch: CGSize?
    /// Height of the menu bar strip the island covers at the top.
    let topInset: CGFloat

    static let flare: CGFloat = 10
    /// The Dynamic Island's rubbery spring: quick, with a little overshoot.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.74)

    init(screen: NSScreen?) {
        notch = screen?.notch
        if let notch {
            topInset = notch.height
        } else if let screen {
            topInset = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        } else {
            topInset = 24
        }
    }

    /// The island when it rests: exactly the notch (invisible on top of it), or nothing at all without a notch.
    var collapsed: CGSize {
        notch ?? CGSize(width: 180, height: 0)
    }

    /// Room at the top that the content must leave free: the notch hides it.
    var contentTop: CGFloat { notch?.height ?? 8 }

    /// The controls: one button before setup, four switches and three buttons after.
    @MainActor
    private var home: CGSize {
        let model = AppModel.shared
        return model.isEnrolled ? CGSize(width: 384, height: contentTop + 148) : CGSize(width: 230, height: contentTop + 104)
    }

    @MainActor
    func size(for content: Island.Content) -> CGSize {
        let notchWidth = notch?.width ?? 180
        let top = contentTop
        switch content {
        case let .scan(_, caption):
            return CGSize(width: max(notchWidth + 10, caption == nil ? 190 : 230), height: top + (caption == nil ? 80 : 104))
        case .enroll: return CGSize(width: 330, height: top + 362)
        case .test: return CGSize(width: 360, height: top + 258)
        case .countdown: return CGSize(width: max(notchWidth + 60, 240), height: top + 50)
        case .home: return home
        case .more: return CGSize(width: 390, height: top + 413)
        case .faces:
            let count = AppModel.shared.enrollment?.faces.count ?? 1
            return CGSize(width: 360, height: top + 88 + CGFloat(count) * 41)
        case .password: return CGSize(width: 300, height: top + 98)
        case .access, .camera: return CGSize(width: 250, height: top + 96)
        case .keychain: return CGSize(width: 330, height: top + 116)
        case .update: return CGSize(width: 340, height: top + 132)
        case .ready: return CGSize(width: max(notchWidth + 10, 190), height: top + 86)
        }
    }
}

/// The black island hanging from the top edge: concave flares where it meets the edge, round bottom corners.
struct IslandShape: Shape {
    var flare: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, radius) }
        set { flare = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let f = min(flare, rect.width / 4), r = max(0, min(radius, rect.height - f, (rect.width - 2 * f) / 2))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + f, y: rect.minY + f), control: CGPoint(x: rect.minX + f, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + f, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + f + r, y: rect.maxY), control: CGPoint(x: rect.minX + f, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - f - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - f, y: rect.maxY - r), control: CGPoint(x: rect.maxX - f, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - f, y: rect.minY + f))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - f, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct IslandView: View {
    @ObservedObject var island: Island
    /// Some sizes depend on the app state (the controls before and after setup).
    @ObservedObject private var model = AppModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let geometry = island.geometry
        let size = island.expanded ? island.content.map { island.size(for: $0) } ?? geometry.collapsed : geometry.collapsed
        let flare = island.expanded ? IslandGeometry.flare : 0
        let radius: CGFloat = island.expanded ? (island.content?.kind == 0 || island.content?.kind == 4 ? 30 : 34) : 10
        ZStack(alignment: .top) {
            IslandShape(flare: flare, radius: radius)
                .fill(Color.black)
                .frame(width: size.width + 2 * flare, height: size.height)
                .shadow(color: .black.opacity(island.expanded ? 0.35 : 0), radius: 14, y: 6)
            if island.expanded, let content = island.content {
                IslandContentView(content: content, island: island)
                    .frame(width: size.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    })
                    .onPreferenceChange(ContentHeightKey.self) { height in
                        MainActor.assumeIsolated { island.measured(height, for: content.kind) }
                    }
                    .padding(.top, geometry.contentTop)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .id(island.revision)
                    .transition(.modifier(active: IslandContentTransition(progress: 0), identity: IslandContentTransition(progress: 1)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(Motion.animation(IslandGeometry.spring, reduceMotion: reduceMotion), value: island.expanded)
        .animation(Motion.animation(IslandGeometry.spring, reduceMotion: reduceMotion), value: island.revision)
    }
}

/// Content appears the way the Dynamic Island shows it: out of a blur, growing from the top.
struct IslandContentTransition: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 10)
            .scaleEffect(0.85 + 0.15 * progress, anchor: .top)
    }
}

/// The natural height of the island's content.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// What the island shows.
struct IslandContentView: View {
    let content: Island.Content
    let island: Island

    var body: some View {
        switch content {
        case let .scan(phase, caption):
            VStack(spacing: 10) {
                FaceIDGlyph(phase: phase, size: 54, color: .white)
                    .padding(.top, 12)
                if let caption {
                    Text(caption)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
        case let .enroll(model):
            EnrollView(enroll: model)
                .environmentObject(AppModel.shared)
        case let .test(model):
            TestView(test: model)
                .environmentObject(AppModel.shared)
                .environmentObject(AppSettings.shared)
        case let .countdown(seconds):
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("\(seconds)")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: seconds)
            }
            .padding(.top, 12)
        case .home:
            HomePage()
        case .more:
            MorePage()
        case .faces:
            FacesPage()
        case let .password(model):
            PasswordPage(model: model)
        case .access:
            PermissionPage(kind: .accessibility)
        case .camera:
            PermissionPage(kind: .camera)
        case .keychain:
            KeychainPage()
        case .update:
            UpdatePage()
        case .ready:
            FaceIDGlyph(phase: .success, size: 58)
                .padding(.top, 14)
        }
    }
}
