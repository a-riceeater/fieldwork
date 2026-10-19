import XCTest
import DrillTiming
import DrillCore
import DrillMedia
@testable import DrillDocument

/// Cross-platform golden fixture: the committed demo show must decode and
/// evaluate to the committed positions and audio times on every platform.
/// Regenerate with `fwtool evaluate examples/first-light.fieldwork 0 8 16 24.5 32 36 40`.
final class FixtureTests: XCTestCase {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testDemoShowMatchesGoldenEvaluation() throws {
        let document = try DocumentFile.open(Self.repoRoot.appendingPathComponent("examples/first-light.fieldwork"))
        let golden = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.repoRoot.appendingPathComponent("spec/fixtures/first-light-evaluation.json"))) as! [String: Any]
        let show = document.show
        XCTAssertEqual(golden["show"] as? String, show.title)
        XCTAssertEqual(show.mediaAssets.count, 1)
        let wav = try WAVDecoder.decode(XCTUnwrap(document.assets[show.mediaAssets[0].archivePath]))
        XCTAssertEqual(wav.frameCount, show.mediaAssets[0].frameCount)

        let evaluator = try SceneEvaluator(show: show, movementID: show.movements[0].id)
        for frame in golden["frames"] as! [[String: Any]] {
            let pulse = frame["pulse"] as! Double
            let scene = evaluator.evaluate(pulse: pulse)
            XCTAssertEqual(scene.setIndex, frame["setIndex"] as? Int)
            let time = try evaluator.map.audioTime(atPulse: Rational(Int64((pulse * 1000).rounded()), 1000))
            XCTAssertEqual(time, frame["audioTime"] as! Double, accuracy: 1e-6)
            let expected = frame["performers"] as! [[String: Any]]
            XCTAssertEqual(expected.count, scene.performers.count)
            for (e, actual) in zip(expected, scene.performers) {
                XCTAssertEqual(e["id"] as? String, actual.id.description)
                XCTAssertEqual(actual.x, e["x"] as! Double, accuracy: 1e-6)
                XCTAssertEqual(actual.y, e["y"] as! Double, accuracy: 1e-6)
            }
        }
    }

    /// Synthetic paths fixture with every segment kind. Regenerate with
    /// `fwtool paths-fixture spec/fixtures/paths.fieldwork`, then
    /// `fwtool evaluate spec/fixtures/paths.fieldwork 0 1 2 3 4 4.5 5 6 7 8 9 10 11 12 13 14`.
    func testPathsFixtureMatchesGoldenEvaluation() throws {
        let document = try DocumentFile.open(Self.repoRoot.appendingPathComponent("spec/fixtures/paths.fieldwork"))
        let golden = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.repoRoot.appendingPathComponent("spec/fixtures/paths-evaluation.json"))) as! [String: Any]
        let show = document.show
        XCTAssertEqual(golden["show"] as? String, show.title)
        XCTAssertNil(document.readOnlyReason)
        let kinds = Set(show.transitions.flatMap { $0.paths.values.flatMap { $0.segments.map(\.kindName) } })
        XCTAssertEqual(kinds, ["hold", "line", "arc"])
        let evaluator = try SceneEvaluator(show: show, movementID: show.movements[0].id)
        for frame in golden["frames"] as! [[String: Any]] {
            let scene = evaluator.evaluate(pulse: frame["pulse"] as! Double)
            XCTAssertEqual(scene.setIndex, frame["setIndex"] as? Int)
            let expected = frame["performers"] as! [[String: Any]]
            XCTAssertEqual(expected.count, scene.performers.count)
            for (e, actual) in zip(expected, scene.performers) {
                XCTAssertEqual(e["id"] as? String, actual.id.description)
                XCTAssertEqual(actual.x, e["x"] as! Double, accuracy: 1e-6)
                XCTAssertEqual(actual.y, e["y"] as! Double, accuracy: 1e-6)
            }
        }
    }
}
