import Accelerate
import Foundation

/// Compares face embeddings. Embeddings are unit vectors, so their dot product is the cosine similarity:
/// about 0.6–0.9 for two camera frames of the same person, below 0.3 for different people.
public enum FaceMatcher {
    public static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vDSP.sumOfSquares(vector).squareRoot()
        guard norm > 0 else { return vector }
        return vDSP.divide(vector, norm)
    }

    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        vDSP.dot(a, b)
    }

    /// Similarity to the closest enrolled template.
    public static func bestSimilarity(_ embedding: [Float], to templates: [[Float]]) -> Float {
        templates.reduce(-1) { max($0, similarity(embedding, $1)) }
    }
}
