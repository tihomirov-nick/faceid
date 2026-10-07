import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// Camera frames and photos are handled the same way: as 32BGRA pixel buffers.
public enum PixelBuffers {
    /// Decodes a photo (JPEG, PNG, HEIC…) into a BGRA pixel buffer, turned upright by its EXIF orientation.
    public static func load(_ url: URL) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let image: CGImage?
        if orientation == 1 {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 4096
            let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 4096
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            ] as CFDictionary)
        }
        return image.flatMap(make(from:))
    }

    /// Draws an image into a new BGRA buffer without color conversion (pixel values stay as in the file).
    public static func make(from image: CGImage) -> CVPixelBuffer? {
        guard let buffer = create(width: image.width, height: image.height) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    public static func create(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        return buffer
    }

    /// A copy of a BGRA buffer as an image (previews, debugging).
    public static func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                  data: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        return context.makeImage()
    }
}

/// Read access to the pixels of a locked BGRA buffer.
struct BGRAPixels {
    let base: UnsafePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int

    /// Runs `body` with the buffer locked for reading; nil for buffers that are not 32BGRA.
    static func read<T>(_ buffer: CVPixelBuffer, _ body: (BGRAPixels) -> T) -> T? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let pixels = BGRAPixels(
            base: UnsafePointer(base.assumingMemoryBound(to: UInt8.self)),
            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)
        )
        return body(pixels)
    }

    /// Bilinear sample at (x, y) where integer coordinates are pixel centers; outside the image is black
    /// (the same as OpenCV's INTER_LINEAR with BORDER_CONSTANT). Returns (b, g, r).
    @inline(__always)
    func sample(_ x: Double, _ y: Double) -> (Double, Double, Double) {
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let fx = x - Double(x0), fy = y - Double(y0)
        var b = 0.0, g = 0.0, r = 0.0
        for dy in 0...1 {
            let yy = y0 + dy
            guard yy >= 0, yy < height else { continue }
            let wy = dy == 0 ? 1 - fy : fy
            let row = base + yy * bytesPerRow
            for dx in 0...1 {
                let xx = x0 + dx
                guard xx >= 0, xx < width else { continue }
                let w = wy * (dx == 0 ? 1 - fx : fx)
                let p = row + xx * 4
                b += w * Double(p[0]); g += w * Double(p[1]); r += w * Double(p[2])
            }
        }
        return (b, g, r)
    }

    /// Mean brightness (0...255) of a rectangle, sampled on a coarse grid.
    func meanLuma(in rect: CGRect, step: Int = 4) -> Double {
        let x0 = max(0, Int(rect.minX)), x1 = min(width, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY)), y1 = min(height, Int(rect.maxY))
        guard x1 > x0, y1 > y0 else { return 0 }
        var sum = 0.0, count = 0.0
        var y = y0
        while y < y1 {
            let row = base + y * bytesPerRow
            var x = x0
            while x < x1 {
                let p = row + x * 4
                sum += 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
                count += 1
                x += step
            }
            y += step
        }
        return count > 0 ? sum / count : 0
    }
}
