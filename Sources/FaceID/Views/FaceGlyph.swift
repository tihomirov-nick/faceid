import AppKit
import SwiftUI

/// What a glyph shows, as with Face ID on iPhone.
enum GlyphPhase: Equatable {
    case idle
    case scanning
    case success
    case failure
}

// MARK: - Face ID glyph

/// Face ID as on iPhone: FaceID's face (`FaceMarkView`) while scanning; when recognized, the face gives way to a glowing
/// green ring that tumbles in, settles and gets a checkmark (the Dynamic Island animation); when not, the face shakes "no".
struct FaceIDGlyph: View {
    var phase: GlyphPhase = .idle
    var size: CGFloat = 64
    var color: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var successStart: Date?
    @State private var shakes = 0
    @State private var breathe = false

    /// The green of the Face ID checkmark in the Dynamic Island.
    static let green = Color(red: 0.651, green: 0.973, blue: 0.592)

    var body: some View {
        ZStack {
            FaceMarkView(pointSize: size * 0.9)
                .foregroundStyle(color)
                .opacity(phase == .success ? 0 : (phase == .scanning && breathe ? 0.55 : 1))
                .scaleEffect(phase == .success ? 0.6 : 1)
                .animation(.easeOut(duration: 0.18), value: phase)
                .keyframeAnimator(initialValue: 0.0, trigger: shakes) { view, offset in
                    view.offset(x: offset)
                } keyframes: { _ in
                    // A head shake: "no".
                    KeyframeTrack {
                        LinearKeyframe(0, duration: 0.01)
                        SpringKeyframe(-size * 0.16, duration: 0.08)
                        SpringKeyframe(size * 0.16, duration: 0.1)
                        SpringKeyframe(-size * 0.12, duration: 0.1)
                        SpringKeyframe(size * 0.08, duration: 0.1)
                        SpringKeyframe(0, duration: 0.14)
                    }
                }
            if phase == .success {
                TimelineView(.animation(paused: reduceMotion)) { context in
                    SuccessRing(time: successTime(at: context.date), size: size)
                }
            }
        }
        .frame(width: size, height: size)
        .onChange(of: phase) { _, new in
            successStart = new == .success ? Date() : nil
            if new == .failure && !reduceMotion { shakes += 1 }
            startBreathing()
        }
        .onAppear {
            if phase == .success { successStart = Date() }
            startBreathing()
        }
        .accessibilityLabel("FaceID")
    }

    #if DEBUG
    /// Debug hooks: the success animation shown at this moment (seconds) whatever the clock says, for drawing it offscreen.
    static var debugSuccessTime: Double?
    #endif

    private func successTime(at date: Date) -> Double {
        #if DEBUG
        if let time = Self.debugSuccessTime { return time }
        #endif
        return reduceMotion ? 10 : successStart.map { date.timeIntervalSince($0) } ?? 10
    }

    private func startBreathing() {
        guard phase == .scanning, !reduceMotion else {
            breathe = false
            return
        }
        withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) { breathe = true }
    }
}

/// FaceID's face (`FaceMark`) in SwiftUI, where the island used the SF Symbol `faceid` at light weight: laid out as that
/// symbol was for a font of `pointSize` (1.19 × 1.11 of it), with the mark in the middle as big as the symbol's ink
/// (0.935 of it) and with lines as thin, filled with the foreground style.
struct FaceMarkView: View {
    var pointSize: CGFloat

    var body: some View {
        FaceMarkShape()
            .frame(width: pointSize * 0.935, height: pointSize * 0.935)
            .frame(width: (pointSize * 1.19).rounded(), height: (pointSize * 1.11).rounded())
    }
}

/// The mark with light lines, in the largest square that fits.
struct FaceMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let move = CGAffineTransform(translationX: rect.midX - size / 2, y: rect.midY - size / 2)
        var path = Path()
        for part in FaceMark.corners(size: size, lines: .light) + FaceMark.face(size: size, lines: .light) {
            path.addPath(Path(part), transform: move)
        }
        return path
    }
}

/// The success animation at `time` seconds: the ring flies in edge-on, tumbles (its axis turning from horizontal
/// to vertical) with motion trails, faces front, and the checkmark draws inside.
struct SuccessRing: View {
    let time: Double
    let size: CGFloat
    static let spin = 0.85
    static let check = 0.24

    var body: some View {
        let line = size * 0.075
        let checked = min(1, max(0, (time - Self.spin) / Self.check))
        let glow = time < Self.spin ? 0.9 : max(0.35, 0.9 - (time - Self.spin) * 1.5)
        ZStack {
            // Trails: the same ring a moment earlier, fainter.
            ForEach([0.05, 0.025], id: \.self) { lag in
                ring(at: time - lag, line: line).opacity(time - lag > 0 && time < Self.spin ? 0.3 : 0)
            }
            ring(at: time, line: line)
            CheckmarkShape()
                .trim(from: 0, to: checked)
                .stroke(FaceIDGlyph.green, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
        }
        .shadow(color: FaceIDGlyph.green.opacity(glow), radius: size * 0.09)
        .shadow(color: FaceIDGlyph.green.opacity(glow * 0.5), radius: size * 0.2)
    }

    private func ring(at t: Double, line: CGFloat) -> some View {
        let p = min(1, max(0, t / Self.spin))
        // Slow at both ends: the ring lingers edge-on as it appears and settles gently facing front.
        let eased = p * p * (3 - 2 * p)
        // Starts edge-on, a turn and a quarter away from facing front; the axis turns from x to y.
        let angle = (1 - eased) * 450
        let axis = eased * .pi / 2
        return Circle()
            .stroke(FaceIDGlyph.green, lineWidth: line)
            .padding(line / 2 + size * 0.08)
            .rotation3DEffect(.degrees(angle), axis: (x: cos(axis), y: sin(axis), z: 0), perspective: 0.35)
            .scaleEffect(0.7 + 0.3 * min(1, p * 3))
            .opacity(min(1, p * 8))
    }
}

struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let o = CGPoint(x: rect.midX - s / 2, y: rect.midY - s / 2)
        var path = Path()
        path.move(to: CGPoint(x: o.x + 0.34 * s, y: o.y + 0.51 * s))
        path.addLine(to: CGPoint(x: o.x + 0.45 * s, y: o.y + 0.63 * s))
        path.addLine(to: CGPoint(x: o.x + 0.66 * s, y: o.y + 0.37 * s))
        return path
    }
}

// MARK: - Haptics

/// A tap on the trackpad, like the haptic of Face ID on iPhone (felt when a finger rests on the trackpad).
enum Haptics {
    static func success() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// A switch was flipped.
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    static func failure() {
        let performer = NSHapticFeedbackManager.defaultPerformer
        performer.perform(.generic, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { performer.perform(.generic, performanceTime: .now) }
    }
}

// MARK: - Menu bar

extension NSImage {
    /// FaceID's face (`FaceMark`) as a template image for the menu bar, at rest (see `MenuBarIcon`).
    static func faceGlyph() -> NSImage {
        MenuBarIcon.image(.init())
    }
}
