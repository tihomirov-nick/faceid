import CoreGraphics
import XCTest
@testable import FaceCore

final class BlinkTrackerTests: XCTestCase {
    func testQuickCloseAndOpenIsABlink() {
        var blink = BlinkTracker()
        blink.add(openness: 1, at: 0)
        blink.add(openness: 0.2, at: 0.1)
        XCTAssertFalse(blink.seen)
        blink.add(openness: 0.95, at: 0.3)
        XCTAssertTrue(blink.seen)
    }

    func testLongClosedEyesAreNotABlink() {
        var blink = BlinkTracker()
        blink.add(openness: 1, at: 0)
        blink.add(openness: 0.2, at: 0.1)
        blink.add(openness: 0.2, at: 1.5)
        blink.add(openness: 1, at: 1.6)
        XCTAssertFalse(blink.seen)
    }

    func testEyesThatStartClosedDoNotCount() {
        // A photo with closed eyes swapped for one with open eyes is not a blink either way, but the tracker at
        // least needs open eyes before the closing.
        var blink = BlinkTracker()
        blink.add(openness: 0.2, at: 0)
        blink.add(openness: 1, at: 0.2)
        XCTAssertFalse(blink.seen)
    }
}

final class EnrollmentTests: XCTestCase {
    private func unit(_ values: [Float]) -> [Float] {
        FaceMatcher.normalized(values + Array(repeating: 0, count: FaceEmbedder.dimension - values.count))
    }

    private func shot(_ values: [Float]) -> Enrollment.Template {
        .init(vector: unit(values), yaw: 0, pitch: 0, appearance: 0)
    }

    func testSimilarityIsTheMeanOfTheThreeClosest() {
        let enrollment = Enrollment(face: "a", templates: [shot([1, 0]), shot([0, 1]), shot([1, 1]), shot([-1, 0])], openEyes: 0.25)
        // Against (1, 0): 1, 0, 0.707, -1 → the three best are 1, 0.707, 0.
        XCTAssertEqual(enrollment.similarity(unit([1, 0])), (1 + 0.70710678 + 0) / 3, accuracy: 1e-5)
    }

    func testLearningAddsOnlyNewLooksAndKeepsTheLatestTwelvePerFace() {
        var enrollment = Enrollment(face: "a", templates: [shot([1, 0])], openEyes: 0.25)
        XCTAssertNil(enrollment.learning(unit([1, 0.01])), "almost the same as a stored shot")
        for i in 0..<15 {
            // Each new look shares a part with the enrolled face and has its own part.
            var look = [Float](repeating: 0, count: i + 2)
            look[0] = 0.6
            look[i + 1] = 1
            if let updated = enrollment.learning(unit(look)) { enrollment = updated }
        }
        XCTAssertEqual(enrollment.templates.filter(\.learned).count, 12)
        XCTAssertEqual(enrollment.templates.filter { !$0.learned }.count, 1, "recorded shots are never dropped")
    }

    func testFacesCanBeAddedRecordedAgainRenamedAndRemoved() {
        var enrollment = Enrollment(face: "a", templates: [shot([1, 0]), shot([0.9, 0.1])], openEyes: 0.25)
        enrollment = enrollment.adding(face: "b", templates: [shot([0, 1])])
        XCTAssertEqual(enrollment.faces.map(\.id), [0, 1])
        XCTAssertEqual(enrollment.shots(of: 1), 1)
        enrollment = enrollment.replacing(face: 0, with: [shot([1, 1])])
        XCTAssertEqual(enrollment.shots(of: 0), 1)
        enrollment = enrollment.renaming(face: 1, to: "c")
        XCTAssertEqual(enrollment.faces.last?.name, "c")
        let without = enrollment.removing(face: 0)
        XCTAssertEqual(without?.faces.map(\.id), [1])
        XCTAssertEqual(without?.templates.count, 1)
        XCTAssertNil(without?.removing(face: 1), "the last face cannot be removed, only reset")
    }

    /// Faces saved by the first version (no list of faces, learned shots as appearance 2) still load.
    func testFirstVersionDataIsMigrated() throws {
        struct OldTemplate: Codable { var vector: [Float]; var yaw: Double; var pitch: Double; var appearance: Int }
        struct Old: Codable { var version = 1; var templates: [OldTemplate]; var openEyes: Double; var created: Date }
        let old = Old(templates: [OldTemplate(vector: unit([1, 0]), yaw: 0, pitch: 0, appearance: 0),
                                  OldTemplate(vector: unit([0, 1]), yaw: 0, pitch: 0, appearance: 1),
                                  OldTemplate(vector: unit([1, 1]), yaw: 0, pitch: 0, appearance: 2)],
                      openEyes: 0.3, created: Date(timeIntervalSince1970: 0))
        let data = try PropertyListEncoder().encode(old)
        let enrollment = try PropertyListDecoder().decode(Enrollment.self, from: data)
        XCTAssertEqual(enrollment.faces.map(\.id), [0, 1])
        XCTAssertEqual(enrollment.templates.filter(\.learned).map(\.appearance), [0])
        XCTAssertEqual(enrollment.shots(of: 0), 2)
        XCTAssertEqual(enrollment.version, 2)
    }
}

final class SecretRecordTests: XCTestCase {
    func testThePlainAttributeSaysWhatTheItemHolds() {
        let both = SecretStore.Record(face: Data([1, 2]), password: "x")
        XCTAssertEqual(String(decoding: both.contents, as: UTF8.self), "face,password")
        XCTAssertTrue(SecretStore.Record.holds("face", in: both.contents))
        XCTAssertTrue(SecretStore.Record.holds("password", in: both.contents))

        let face = SecretStore.Record(face: Data([1]), password: nil)
        XCTAssertTrue(SecretStore.Record.holds("face", in: face.contents))
        XCTAssertFalse(SecretStore.Record.holds("password", in: face.contents))

        XCTAssertTrue(SecretStore.Record().isEmpty)
        XCTAssertFalse(SecretStore.Record.holds("face", in: nil))
        // "face" must not be found inside another word.
        XCTAssertFalse(SecretStore.Record.holds("face", in: Data("faces".utf8)))
    }

    func testTheRecordSurvivesEncoding() throws {
        let record = SecretStore.Record(face: Data(repeating: 7, count: 300), password: "пароль с пробелом")
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let decoded = try PropertyListDecoder().decode(SecretStore.Record.self, from: encoder.encode(record))
        XCTAssertEqual(decoded, record)
    }
}
