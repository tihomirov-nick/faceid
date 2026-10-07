import AppKit
import CoreVideo
import FaceCore
import QuartzCore
import SwiftUI

/// Passes camera frames to a preview without going through SwiftUI state (30 frames a second).
final class PreviewFeed: @unchecked Sendable {
    private let lock = NSLock()
    private weak var view: PreviewLayerView?
    private var pending = false

    fileprivate func attach(_ view: PreviewLayerView) {
        lock.withLock { self.view = view }
    }

    /// Shows a frame; frames arriving while the previous one is still waiting for the main thread are skipped.
    func push(_ buffer: CVPixelBuffer) {
        let skip = lock.withLock {
            if pending { return true }
            pending = true
            return false
        }
        guard !skip else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let view = self.lock.withLock {
                self.pending = false
                return self.view
            }
            view?.show(buffer)
        }
    }
}

/// The camera picture, mirrored like FaceTime and filling its frame.
struct CameraPreview: NSViewRepresentable {
    let feed: PreviewFeed

    func makeNSView(context: Context) -> PreviewLayerView {
        let view = PreviewLayerView()
        feed.attach(view)
        return view
    }

    func updateNSView(_ view: PreviewLayerView, context: Context) {
        feed.attach(view)
    }
}

final class PreviewLayerView: NSView {
    private let imageLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    func show(_ buffer: CVPixelBuffer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
            imageLayer.contents = surface
        } else {
            imageLayer.contents = PixelBuffers.cgImage(from: buffer)
        }
        CATransaction.commit()
    }
}

/// Maps image pixels to a preview of `viewSize` that fills its frame and is mirrored.
struct PreviewMapping {
    let imageSize: CGSize
    let viewSize: CGSize

    func point(_ p: CGPoint) -> CGPoint {
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let x = (viewSize.width - imageSize.width * scale) / 2 + p.x * scale
        let y = (viewSize.height - imageSize.height * scale) / 2 + p.y * scale
        return CGPoint(x: viewSize.width - x, y: y)
    }

    func rect(_ r: CGRect) -> CGRect {
        let a = point(CGPoint(x: r.minX, y: r.minY)), b = point(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

/// A placeholder in place of the picture: no camera permission, camera busy, and so on.
struct CameraUnavailableView: View {
    let message: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.8))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
            if let action {
                Button(action.title, action: action.run)
                    .appButton(.secondary)
                    .environment(\.colorScheme, .dark)
            }
        }
        .padding(20)
    }
}
