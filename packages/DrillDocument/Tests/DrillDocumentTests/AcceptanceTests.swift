import XCTest
import DrillTiming
import DrillCore
import DrillMedia
import DrillExport
@testable import DrillDocument

/// The prompt's acceptance demonstration, minus the native UI: every step goes
/// through the same commands, codec and exporters the apps use.
final class AcceptanceTests: XCTestCase {
    func testThirtyTwoPerformerShowEndToEnd() throws {
        // Create a 32-performer show on a football field.
        let session = try DocumentSession(show: try Show.makeNew(title: "Acceptance", field: .make(.collegeFootball), measures: 16))
        try session.perform(try session.show.makeRoster([
            RosterSectionRequest(name: "Trumpet", prefix: "T", count: 12),
            RosterSectionRequest(name: "Mellophone", prefix: "M", count: 8),
            RosterSectionRequest(name: "Low Brass", prefix: "B", count: 12),
        ]))
        XCTAssertEqual(session.show.performers.count, 32)
        let ids = session.show.performers.map(\.id)
        let preset = session.show.sets[0].id
        let step = session.show.field.stepSize

        // A line and an arc.
        try session.perform(try session.show.makeForm(.line(start: Point2(-31 * step, 0), end: Point2(31 * step, 0)), members: Array(ids[0..<16]), at: preset))
        try session.perform(try session.show.makeForm(.arc(start: Point2(-15 * step, 8 * step), end: Point2(15 * step, 8 * step), bulge: 6 * step),
                                                      members: Array(ids[16...]), at: preset))
        XCTAssertEqual(session.show.forms.count, 2)

        // A 16-count arrival; move everyone 8 steps toward the back sideline.
        try session.perform(try session.show.makeCreateSet(after: preset, counts: 16))
        let set2 = session.show.sets[1].id
        try session.perform(try session.show.makeTranslate(ids, at: set2, by: Point2(0, 8 * step)))
        let movedY = session.show.formation(set2)[ids[0]].position!.y

        // Undo/redo.
        session.undo()
        XCTAssertEqual(session.show.formation(set2)[ids[0]].position!.y, 0, accuracy: 1e-12)
        session.redo()
        XCTAssertEqual(session.show.formation(set2)[ids[0]].position!.y, movedY)

        // Import audio (an original generated click track at 120 BPM with 2 s of lead-in).
        let rate = 22_050
        var samples = [Float](repeating: 0, count: rate * 30)
        for beat in 0..<56 {
            let start = Int((2.0 + Double(beat) * 0.5) * Double(rate))
            for k in 0..<300 where start + k < samples.count { samples[start + k] = Float(sin(Double(k) * 0.7)) * 0.6 }
        }
        let wav = WAVDecoder.encode16(samples, sampleRate: rate)
        let pcm = try WAVDecoder.decode(wav)
        var document = ShowDocument(show: session.show)
        let asset = document.embed(wav, fileExtension: "wav", originalFilename: "click.wav", sampleRate: pcm.sampleRate,
                                   frameCount: pcm.frameCount, channelCount: pcm.channelCount)
        let movement = session.show.movements[0].id
        try session.perform(try session.show.makeImportAudio(asset, movementID: movement))

        // Align the first downbeat, then a later measure, to exact timestamps.
        var map = try session.timingMap(for: movement)
        try session.perform(try session.show.makeAlignHere(movementID: movement, cursor: try map.cursor(measureNumber: 1, beat: 1),
                                                           sampleFrame: Int64((2.0 * Double(rate)).rounded())).command)
        map = try session.timingMap(for: movement)
        let aligned = try session.show.makeAlignHere(movementID: movement, cursor: try map.cursor(measureNumber: 5, beat: 1),
                                                     sampleFrame: Int64((10.05 * Double(rate)).rounded()))
        try session.perform(aligned.command)
        // Anchors are sample-exact: timestamps agree with the request to within half a sample.
        let halfSample = 0.5 / Double(rate)
        XCTAssertEqual(aligned.report.intervals.first?.scale ?? 0, 8.05 / 8.0, accuracy: halfSample / 8)

        // Scrub/play across the set boundary: the evaluator is driven by audio time.
        map = try session.timingMap(for: movement)
        let evaluator = try SceneEvaluator(show: session.show, movementID: movement, map: map)
        let arrivalTime = try map.audioTime(at: session.show.set(set2)!.cursor)
        XCTAssertEqual(arrivalTime, 10.05, accuracy: halfSample, "set 2 arrives at m5 b1, the second pin")
        var lastY = -Double.infinity
        for t in stride(from: arrivalTime - 4, through: arrivalTime + 1, by: 0.05) {
            let y = evaluator.evaluate(audioTime: t).performers[0].y
            XCTAssertGreaterThanOrEqual(y, lastY - 1e-12)
            lastY = y
        }
        XCTAssertEqual(evaluator.evaluate(audioTime: arrivalTime + 0.5).performers[0].y, movedY, accuracy: 1e-9)
        XCTAssertEqual(evaluator.evaluate(audioTime: arrivalTime + 0.5).setIndex, 1)

        // Save, "quit", reopen and verify positions and timing.
        document.show = session.show
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fw-accept-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Acceptance.fieldwork")
        try DocumentFile.save(document, to: url)
        session.markSaved()
        let reopened = try DocumentFile.open(url)
        XCTAssertEqual(reopened.show, session.show)
        let reopenedMap = try reopened.show.timingMap(for: movement)
        XCTAssertEqual(try reopenedMap.audioTime(at: reopened.show.set(set2)!.cursor), arrivalTime)
        XCTAssertEqual(reopened.show.formation(set2)[ids[31]], session.show.formation(set2)[ids[31]])
        XCTAssertEqual(reopened.show.forms, session.show.forms)
        XCTAssertEqual(try WAVDecoder.decode(reopened.assets[asset.archivePath]!).frameCount, pcm.frameCount)

        // Export a readable coordinate PDF.
        let pdf = try CoordinateSheet.render(reopened.show, movementID: movement)
        let text = String(decoding: pdf, as: UTF8.self)
        XCTAssertTrue(text.contains("/Count 34"))   // 32 sheets + 2 set charts
        XCTAssertTrue(text.contains("(00:10.050) Tj"), "audio time of the aligned arrival")
        XCTAssertTrue(text.contains("(m5 b1) Tj"))
    }
}
