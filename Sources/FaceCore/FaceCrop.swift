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
