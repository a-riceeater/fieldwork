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
}
