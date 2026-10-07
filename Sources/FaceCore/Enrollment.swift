import Foundation

/// The enrolled faces: one or more (the owner in glasses, a second look, another person allowed to unlock),
/// each with shots from different head turns. Stored in the Keychain by `FaceStore`.
public struct Enrollment: Codable, Sendable, Equatable {
    public struct Face: Codable, Sendable, Equatable, Identifiable {
        public var id: Int
        public var name: String
        public var created: Date

        public init(id: Int, name: String, created: Date = Date()) {
            self.id = id
            self.name = name
            self.created = created
        }
    }

    public struct Template: Codable, Sendable, Equatable {
        public var vector: [Float]
        /// Head turn when the template was taken, in degrees.
        public var yaw: Double
        public var pitch: Double
        /// The face (`Face.id`) this shot belongs to.
        public var appearance: Int
        /// Learned after a sure match rather than recorded during setup.
        public var learned: Bool

        public init(vector: [Float], yaw: Double, pitch: Double, appearance: Int, learned: Bool = false) {
            self.vector = vector
            self.yaw = yaw
            self.pitch = pitch
            self.appearance = appearance
            self.learned = learned
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            vector = try container.decode([Float].self, forKey: .vector)
            yaw = try container.decode(Double.self, forKey: .yaw)
            pitch = try container.decode(Double.self, forKey: .pitch)
            appearance = try container.decode(Int.self, forKey: .appearance)
            learned = try container.decodeIfPresent(Bool.self, forKey: .learned) ?? false
        }
    }

    public var version = 2
    public var faces: [Face]
    public var templates: [Template]
    /// Typical eye openness with open eyes (`DetectedFace.eyeOpenness`): the reference for the "eyes open" and
    /// blink checks.
    public var openEyes: Double
    public var created: Date

    /// The first face.
    public init(face name: String, templates: [Template], openEyes: Double, created: Date = Date()) {
        faces = [Face(id: 0, name: name, created: created)]
        self.templates = templates.map { var template = $0; template.appearance = 0; return template }
        self.openEyes = openEyes
        self.created = created
    }

    private enum CodingKeys: String, CodingKey {
        case version, faces, templates, openEyes, created
    }

    /// Version 1 had no list of faces: shots of appearance 0 were the face, 1 a second look, 2 shots learned later.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        templates = try container.decode([Template].self, forKey: .templates)
        openEyes = try container.decode(Double.self, forKey: .openEyes)
        created = try container.decode(Date.self, forKey: .created)
        if var faces = try container.decodeIfPresent([Face].self, forKey: .faces) {
            // The default name used to be written with "ё".
            for index in faces.indices where faces[index].name == "Моё лицо" { faces[index].name = Self.firstName }
            self.faces = faces
        } else {
            for index in templates.indices where templates[index].appearance == 2 {
                templates[index].appearance = 0
                templates[index].learned = true
            }
            faces = [Face(id: 0, name: Self.firstName, created: created)]
            if templates.contains(where: { $0.appearance == 1 }) {
                faces.append(Face(id: 1, name: Self.secondName, created: created))
            }
        }
        version = 2
    }

    /// Names given to faces from the first version (the app renames them through `L` at the UI level if needed).
    public static var firstName: String { L("Мое лицо") }
    static var secondName: String { L("Второй вид") }

    public var vectors: [[Float]] { templates.map(\.vector) }

    public func shots(of face: Int) -> Int {
        templates.filter { $0.appearance == face }.count
    }

    /// Similarity of a live embedding to the enrolled faces: the mean of the three closest templates, which is
    /// steadier than the single closest one and lets a stranger slip through less often.
    public func similarity(_ embedding: [Float]) -> Float {
        let scores = templates.map { FaceMatcher.similarity(embedding, $0.vector) }.sorted(by: >)
        let top = scores.prefix(3)
        return top.isEmpty ? -1 : top.reduce(0, +) / Float(top.count)
    }

    /// Shots learned after sure matches let a face keep up with a growing beard or a new haircut, as Face ID on
    /// iPhone does. Only a match well above the threshold teaches it, so a stranger's lucky near-miss never does.
    static let maxLearned = 12

    /// Adds a learned shot to the face it is closest to, when it shows something new (not almost identical to a
    /// stored shot); that face's oldest learned shot goes when there are too many. Nil when nothing changes.
    public func learning(_ embedding: [Float], yaw: Double = 0, pitch: Double = 0) -> Enrollment? {
        guard embedding.count == FaceEmbedder.dimension,
              let closest = templates.max(by: { FaceMatcher.similarity(embedding, $0.vector) < FaceMatcher.similarity(embedding, $1.vector) }),
              FaceMatcher.similarity(embedding, closest.vector) < 0.9 else { return nil }
        var copy = self
        let face = closest.appearance
        copy.templates.append(Template(vector: embedding, yaw: yaw, pitch: pitch, appearance: face, learned: true))
        let learned = copy.templates.indices.filter { copy.templates[$0].appearance == face && copy.templates[$0].learned }
        if learned.count > Self.maxLearned { copy.templates.remove(at: learned[0]) }
        return copy
    }

    /// One more face, with the next free id.
    public func adding(face name: String, templates new: [Template]) -> Enrollment {
        var copy = self
        let id = (faces.map(\.id).max() ?? -1) + 1
        copy.faces.append(Face(id: id, name: name))
        copy.templates += new.map { var template = $0; template.appearance = id; template.learned = false; return template }
        return copy
    }

    /// The face recorded again: its old shots, learned ones included, are replaced.
    public func replacing(face id: Int, with new: [Template]) -> Enrollment {
        var copy = self
        copy.templates = templates.filter { $0.appearance != id }
            + new.map { var template = $0; template.appearance = id; template.learned = false; return template }
        return copy
    }

    /// Without the face; nil when it was the last one (nothing left to recognize).
    public func removing(face id: Int) -> Enrollment? {
        guard faces.count > 1 else { return nil }
        var copy = self
        copy.faces.removeAll { $0.id == id }
        copy.templates.removeAll { $0.appearance == id }
        return copy
    }

    public func renaming(face id: Int, to name: String) -> Enrollment {
        var copy = self
        if let index = copy.faces.firstIndex(where: { $0.id == id }) { copy.faces[index].name = name }
        return copy
    }
}
