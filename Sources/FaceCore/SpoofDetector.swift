import CoreML
import CoreVideo
import Foundation

/// Tells a live face from a photo or a screen held up to the camera: two MiniFASNet models from
/// Silent-Face-Anti-Spoofing (Minivision, Apache 2.0) look at the face with different amounts of surroundings
/// (print edges, screen bezels, moiré, glare) and their answers are averaged.
public final class SpoofDetector {
    public struct Result: Sendable {
        /// Probability that the camera sees a live face (0...1).
        public var real: Double
        public var fake: Double { 1 - real }
    }

    private struct Model {
        let model: MLModel
        let input: MLMultiArray
        let scale: Double
    }

    /// Input side of both models.
    static let side = 80
    /// (model name, how many face boxes of context it sees)
    static let models: [(String, Double)] = [("MiniFASNetV2", 2.7), ("MiniFASNetV1SE", 4.0)]

    private let models: [Model]

    public init() throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        models = try Self.models.map { name, scale in
            guard let url = AppPaths.spoofModelURL(name) else { throw FaceEmbedder.Failure.modelMissing }
            let input = try MLMultiArray(shape: [1, 3, NSNumber(value: Self.side), NSNumber(value: Self.side)], dataType: .float32)
            return Model(model: try MLModel(contentsOf: url, configuration: configuration), input: input, scale: scale)
        }
    }

    public func evaluate(_ buffer: CVPixelBuffer, face: DetectedFace) throws -> Result {
        var real = 0.0
        for model in models {
            guard let tensor = FaceCrop.contextTensor(from: buffer, faceBox: Self.detectorBox(face), scale: model.scale, side: Self.side) else {
                throw FaceEmbedder.Failure.badOutput
            }
            tensor.withUnsafeBufferPointer { source in
                model.input.dataPointer.assumingMemoryBound(to: Float.self).update(from: source.baseAddress!, count: source.count)
            }
            let features = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: model.input)])
            let output = try model.model.prediction(from: features)
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue, logits.count == 3 else {
                throw FaceEmbedder.Failure.badOutput
            }
            let values = (0..<3).map { logits[$0].doubleValue }
            let top = values.max()!
            let exps = values.map { Foundation.exp($0 - top) }
            real += exps[1] / exps.reduce(0, +)
        }
        return Result(real: real / Double(models.count))
    }

    /// The models were trained on boxes from a RetinaFace-style detector, which are narrower than Vision's and
    /// reach higher up the forehead. Vision's box is reshaped to match (median over LFW against YuNet boxes:
    /// shifted by 0.064 and −0.149 of its size, 0.855 as wide and 1.122 as tall).
    static func detectorBox(_ face: DetectedFace) -> CGRect {
        let box = face.bounds
        return CGRect(x: box.minX + 0.064 * box.width, y: box.minY - 0.149 * box.height,
                      width: box.width * 0.855, height: box.height * 1.122)
    }
}
