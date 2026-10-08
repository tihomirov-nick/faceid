import CoreGraphics
import CoreVideo
import FaceCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Command line tool for checking recognition on photos without the UI:
//   faceid-cli compare <photo> <photo>…          similarity of the first face in each photo to the first photo
//   faceid-cli align <photo> <out.png>           the aligned 112×112 face the model sees
//   faceid-cli embed <list.txt> <out.f32> [--center]
//                                                embeddings of photos listed one per line (128 float32 each,
//                                                zeros when no face was found); --center takes the face nearest
//                                                the middle of the photo (LFW) instead of the largest
//   faceid-cli landmarks <list.txt> <out.jsonl> [--center]
//                                                every Vision landmark of each photo (calibration)
// Messages go to stderr.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func log(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

var arguments = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

let usage = "usage: faceid-cli compare|align|embed|landmarks … (see Sources/FaceIDCLI/main.swift)"
let center = flag("--center")
guard let command = arguments.first else { fail(usage) }
arguments.removeFirst()

let detector = FaceDetector()

/// The face to use in a photo: the largest one, or with --center the one nearest the middle.
func pickFace(_ faces: [DetectedFace], in buffer: CVPixelBuffer) -> DetectedFace? {
    guard center else { return faces.first }
    let mid = CGPoint(x: Double(CVPixelBufferGetWidth(buffer)) / 2, y: Double(CVPixelBufferGetHeight(buffer)) / 2)
    return faces.min { CGPoint(x: $0.bounds.midX, y: $0.bounds.midY).distance(to: mid) < CGPoint(x: $1.bounds.midX, y: $1.bounds.midY).distance(to: mid) }
}

func readList(_ path: String) -> [String] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("can't read \(path)") }
    return text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
}

func face(in path: String) -> (CVPixelBuffer, DetectedFace)? {
    // Vision and Core ML leave autoreleased objects (IOSurfaces among them) behind; without a pool per photo they
    // pile up over a few thousand photos until detection starts failing.
    autoreleasepool {
        guard let buffer = PixelBuffers.load(URL(fileURLWithPath: path)) else {
            log("can't open \(path)")
            return nil
        }
        guard let faces = try? detector.detect(in: buffer), let face = pickFace(faces, in: buffer) else { return nil }
        return (buffer, face)
    }
}

func makeEmbedder() -> FaceEmbedder {
    do {
        return try FaceEmbedder()
    } catch {
        fail("error: \(error.localizedDescription)")
    }
}

switch command {
case "compare":
    guard arguments.count >= 2 else { fail(usage) }
    let embedder = makeEmbedder()
    var reference: [Float]?
    for path in arguments {
        guard let (buffer, face) = face(in: path) else {
            print("\(path)\tno face")
            continue
        }
        let embedding = try embedder.embedding(of: buffer, points: face.points)
        if let reference {
            print(String(format: "%@\t%.3f", path, FaceMatcher.similarity(reference, embedding)))
        } else {
            reference = embedding
            print("\(path)\treference")
        }
    }

case "align":
    guard arguments.count == 2 else { fail(usage) }
    guard let (buffer, face) = face(in: arguments[0]) else { fail("no face in \(arguments[0])") }
    guard let image = FaceCrop.alignedImage(from: buffer, points: face.points),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL,
                                                            UTType.png.identifier as CFString, 1, nil) else {
        fail("can't write \(arguments[1])")
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    log(String(format: "eye distance %.0f px · yaw %@ · pitch %@ · roll %@ · eyes %.2f",
               face.points.eyeDistance, "\(face.yaw ?? .nan)", "\(face.pitch ?? .nan)", "\(face.roll ?? .nan)", face.eyeOpenness))

case "embed":
    guard arguments.count == 2 else { fail(usage) }
    let paths = readList(arguments[0])
    let embedder = makeEmbedder()
    var data = Data(capacity: paths.count * FaceEmbedder.dimension * 4)
    var missing = 0
    let started = Date()
    for (index, path) in paths.enumerated() {
        var vector = [Float](repeating: 0, count: FaceEmbedder.dimension)
        if let (buffer, face) = face(in: path) {
            vector = try autoreleasepool { try embedder.embedding(of: buffer, points: face.points) }
        } else {
            missing += 1
        }
        vector.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)) }
        if (index + 1) % 1000 == 0 { log("\(index + 1) / \(paths.count)") }
    }
    try data.write(to: URL(fileURLWithPath: arguments[1]))
    log(String(format: "%d photos, no face in %d, %.1f s", paths.count, missing, Date().timeIntervalSince(started)))

case "landmarks":
    guard arguments.count == 2 else { fail(usage) }
    let paths = readList(arguments[0])
    var lines: [String] = []
    for path in paths {
        var record: [String: Any] = ["path": path]
        if let buffer = PixelBuffers.load(URL(fileURLWithPath: path)),
           let faces = autoreleasepool(invoking: { try? detector.detect(in: buffer, regions: true) }),
           let face = pickFace(faces, in: buffer) {
            record["bounds"] = [face.bounds.minX, face.bounds.minY, face.bounds.width, face.bounds.height]
            record["regions"] = face.regions.mapValues { $0.map { [$0.x, $0.y] } }
            record["five"] = face.points.array.map { [$0.x, $0.y] }
            record["pose"] = [face.yaw ?? .nan, face.pitch ?? .nan, face.roll ?? .nan].map { $0.isNaN ? NSNull() : $0 as Any }
        }
        let json = try JSONSerialization.data(withJSONObject: record)
        lines.append(String(decoding: json, as: UTF8.self))
    }
    try (lines.joined(separator: "\n") + "\n").write(toFile: arguments[1], atomically: true, encoding: .utf8)
    log("\(paths.count) photos")

default:
    fail(usage)
}
