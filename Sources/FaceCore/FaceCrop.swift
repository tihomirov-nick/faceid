import CoreGraphics
import CoreVideo
import Foundation

/// Face images cut out of a frame for the neural networks.
public enum FaceCrop {
    /// The aligned 112×112 face for the recognition model: three planes R, G, B with values 0...255, rounded like
    /// the 8-bit image OpenCV feeds the model. Nil when the buffer is not 32BGRA.
    public static func alignedTensor(from buffer: CVPixelBuffer, points: FivePoints) -> [Float]? {
        guard let inverse = FaceAlignment.transform(for: points).inverted else { return nil }
        let n = FaceAlignment.size
        return BGRAPixels.read(buffer) { pixels in
            var out = [Float](repeating: 0, count: 3 * n * n)
            out.withUnsafeMutableBufferPointer { planes in
                for v in 0..<n {
                    for u in 0..<n {
                        let x = inverse.a * Double(u) + inverse.b * Double(v) + inverse.tx
                        let y = inverse.c * Double(u) + inverse.d * Double(v) + inverse.ty
                        let (b, g, r) = pixels.sample(x, y)
                        let i = v * n + u
                        planes[i] = Float(r.rounded())
                        planes[n * n + i] = Float(g.rounded())
                        planes[2 * n * n + i] = Float(b.rounded())
                    }
                }
            }
            return out
        }
    }

    /// A square crop around the face box enlarged `scale` times (moved inside the frame when it sticks out,
    /// as in Silent-Face-Anti-Spoofing) and resized to `side`×`side`: planes B, G, R, values 0...255.
    public static func contextTensor(from buffer: CVPixelBuffer, faceBox box: CGRect, scale: Double, side: Int) -> [Float]? {
        BGRAPixels.read(buffer) { pixels in
            let rect = contextRect(box: box, scale: scale, width: pixels.width, height: pixels.height)
            var out = [Float](repeating: 0, count: 3 * side * side)
            // cv2.resize with INTER_LINEAR: pixel centers are mapped onto each other.
            let sx = Double(rect.width) / Double(side), sy = Double(rect.height) / Double(side)
            out.withUnsafeMutableBufferPointer { planes in
                for v in 0..<side {
                    let y = min(max(rect.minY + (Double(v) + 0.5) * sy - 0.5, rect.minY), rect.maxY - 1)
                    for u in 0..<side {
                        let x = min(max(rect.minX + (Double(u) + 0.5) * sx - 0.5, rect.minX), rect.maxX - 1)
                        let (b, g, r) = pixels.sample(x, y)
                        let i = v * side + u
                        planes[i] = Float(b.rounded())
                        planes[side * side + i] = Float(g.rounded())
                        planes[2 * side * side + i] = Float(r.rounded())
                    }
                }
            }
            return out
        }
    }

    /// The enlarged box from Silent-Face-Anti-Spoofing (`CropImage._get_new_box`), in whole pixels.
    static func contextRect(box: CGRect, scale: Double, width: Int, height: Int) -> CGRect {
        let w = Double(width), h = Double(height)
        let s = min((h - 1) / box.height, min((w - 1) / box.width, scale))
        let newW = box.width * s, newH = box.height * s
        let cx = box.midX, cy = box.midY
        var left = cx - newW / 2, top = cy - newH / 2, right = cx + newW / 2, bottom = cy + newH / 2
        if left < 0 { right -= left; left = 0 }
        if top < 0 { bottom -= top; top = 0 }
        if right > w - 1 { left -= right - w + 1; right = w - 1 }
        if bottom > h - 1 { top -= bottom - h + 1; bottom = h - 1 }
        let l = max(0, Int(left)), t = max(0, Int(top)), r = Int(right), b = Int(bottom)
        return CGRect(x: l, y: t, width: max(1, r - l + 1), height: max(1, b - t + 1))
    }

    /// The aligned face as an image, for previews and debugging.
    public static func alignedImage(from buffer: CVPixelBuffer, points: FivePoints) -> CGImage? {
        guard let tensor = alignedTensor(from: buffer, points: points) else { return nil }
        return image(fromPlanes: tensor, side: FaceAlignment.size, order: (0, 1, 2))
    }

    /// Image from three planes; `order` gives the plane index of red, green and blue.
    static func image(fromPlanes planes: [Float], side: Int, order: (Int, Int, Int)) -> CGImage? {
        let count = side * side
        var bytes = [UInt8](repeating: 255, count: count * 4)
        for i in 0..<count {
            bytes[i * 4] = UInt8(clamping: Int(planes[order.0 * count + i]))
            bytes[i * 4 + 1] = UInt8(clamping: Int(planes[order.1 * count + i]))
            bytes[i * 4 + 2] = UInt8(clamping: Int(planes[order.2 * count + i]))
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
