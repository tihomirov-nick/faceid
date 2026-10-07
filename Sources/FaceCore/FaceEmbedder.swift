import CoreML
import CoreVideo
import Foundation

/// Turns an aligned face into 128 numbers with SFace (OpenCV Zoo, Apache 2.0) converted to Core ML.
/// Photos of the same person give vectors pointing the same way; `FaceMatcher` compares them.
public final class FaceEmbedder {
    public static let dimension = 128
    private let model: MLModel
    private let input: MLMultiArray

    public enum Failure: LocalizedError {
        case modelMissing
        case badOutput

        public var errorDescription: String? {
            switch self {
            case .modelMissing: L("Не найдена модель распознавания лиц (SFace.mlmodelc)")
            case .badOutput: L("Модель распознавания вернула неожиданный результат")
            }
        }
    }

    public init(modelURL: URL? = AppPaths.recognitionModelURL()) throws {
        guard let modelURL else { throw Failure.modelMissing }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        input = try MLMultiArray(shape: [1, 3, NSNumber(value: FaceAlignment.size), NSNumber(value: FaceAlignment.size)],
                                 dataType: .float32)
    }

    /// Unit-length embedding of the face at `points` in `buffer` (32BGRA).
    public func embedding(of buffer: CVPixelBuffer, points: FivePoints) throws -> [Float] {
        guard let tensor = FaceCrop.alignedTensor(from: buffer, points: points) else { throw Failure.badOutput }
        return try embedding(tensor: tensor)
    }

    /// Unit-length embedding of an aligned face given as R, G, B planes of 112×112 values 0...255.
    public func embedding(tensor: [Float]) throws -> [Float] {
        precondition(tensor.count == input.count)
        tensor.withUnsafeBufferPointer { source in
            input.dataPointer.assumingMemoryBound(to: Float.self).update(from: source.baseAddress!, count: source.count)
        }
        let features = try MLDictionaryFeatureProvider(dictionary: ["data": MLFeatureValue(multiArray: input)])
        let output = try model.prediction(from: features)
        guard let array = output.featureValue(for: "embedding")?.multiArrayValue, array.count == Self.dimension else {
            throw Failure.badOutput
        }
        var vector = [Float](repeating: 0, count: Self.dimension)
        switch array.dataType {
        case .float32:
            let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<Self.dimension { vector[i] = pointer[i * array.strides.last!.intValue] }
        default:
            for i in 0..<Self.dimension { vector[i] = array[i].floatValue }
        }
        return FaceMatcher.normalized(vector)
    }
}
