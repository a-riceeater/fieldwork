import XCTest
@testable import DrillTiming

final class TimingConflictTests: XCTestCase {
    let asset = MediaAssetID()
    let rate = 44_100.0

    func makeAnchored() throws -> (TimingTrack, AudioAnchor, AudioAnchor) {
        var track = try TimingTrack.make(meter: Meter(4, 4), bpm: 120, measures: 24)
        let map = try TimingMap(track: track, assetID: asset)
        let a = AudioAnchor(cursor: try map.cursor(measureNumber: 1, beat: 1), assetID: asset, sampleFrame: Int64(12.4 * rate), sampleRate: rate)
        let b = AudioAnchor(cursor: try map.cursor(measureNumber: 17, beat: 1), assetID: asset, sampleFrame: Int64(44.6 * rate), sampleRate: rate)
        track = try TimingEditor.addAnchor(a, to: track).track
        track = try TimingEditor.addAnchor(b, to: track).track
        return (track, a, b)
    }

    func testNonMonotonicAnchorOffersOptionsAndChangesNothing() throws {
        let (track, a, b) = try makeAnchored()
        let map = try TimingMap(track: track, assetID: asset)
        // m9 pinned after the m17 timestamp: contradiction.
        let bad = AudioAnchor(cursor: try map.cursor(measureNumber: 9, beat: 1), assetID: asset, sampleFrame: Int64(50 * rate), sampleRate: rate)
        XCTAssertThrowsError(try TimingEditor.addAnchor(bad, to: track)) { error in
            let conflict = error as! TimingEditConflict
            XCTAssertTrue(conflict.options.contains(.replaceAnchor(b.id)))
            XCTAssertTrue(conflict.options.contains(.cancel))
            XCTAssertFalse(conflict.options.contains(.replaceAnchor(a.id)))
        }
        XCTAssertEqual(track.anchors.count, 2, "input track untouched")
        // Choosing to replace the conflicting pin applies cleanly.
        let resolved = try TimingEditor.addAnchor(bad, to: track, resolution: .replaceAnchor(b.id))
        XCTAssertEqual(resolved.track.anchors.map(\.id), [a.id, bad.id])
    }

    func testDuplicatePinOffersReplace() throws {
        let (track, _, b) = try makeAnchored()
        let map = try TimingMap(track: track, assetID: asset)
        let dup = AudioAnchor(cursor: try map.cursor(measureNumber: 17, beat: 1), assetID: asset, sampleFrame: Int64(44.7 * rate), sampleRate: rate)
        XCTAssertThrowsError(try TimingEditor.addAnchor(dup, to: track)) { error in
            XCTAssertEqual((error as! TimingEditConflict).options, [.replaceAnchor(b.id), .cancel])
        }
    }

    func testOutOfRangeImpliedTempoIsRejected() throws {
        let (track, _, b) = try makeAnchored()
        // Squeezing 64 beats into 2 seconds implies an absurd tempo.
        XCTAssertThrowsError(try TimingEditor.moveAnchor(b.id, toSampleFrame: Int64(14.4 * rate), in: track)) { error in
            let conflict = error as! TimingEditConflict
            XCTAssertTrue(conflict.message.contains("BPM"))
            XCTAssertEqual(conflict.options, [.cancel])
        }
    }

    func testPreserveNotatedTempoConflictOffersReleaseFitCancel() throws {
        var (track, a, b) = try makeAnchored()
        track.fitMode = .preserveNotatedTempo
        XCTAssertThrowsError(try TimingEditor.setTempo(measures: 4...7, bpm: 100, in: track, assetID: asset)) { error in
            let conflict = error as! TimingEditConflict
            XCTAssertEqual(conflict.options, [.releaseAnchor(a.id), .releaseAnchor(b.id), .fitBetweenAnchors, .cancel])
        }
        // Measures after the last pin are free to change.
        XCTAssertNoThrow(try TimingEditor.setTempo(measures: 18...20, bpm: 100, in: track, assetID: asset))

        // Fit keeps both pins exactly.
        let fitted = try TimingEditor.setTempo(measures: 4...7, bpm: 100, in: track, assetID: asset, resolution: .fitBetweenAnchors)
        let map = try TimingMap(track: fitted.track, assetID: asset)
        XCTAssertEqual(try map.audioTime(at: map.cursor(measureNumber: 17, beat: 1)), 44.6, accuracy: 1e-6)
        XCTAssertEqual(try map.audioTime(at: map.cursor(measureNumber: 1, beat: 1)), 12.4, accuracy: 1e-6)

        // Releasing the later pin restores the notated tempo after the first pin.
        let released = try TimingEditor.setTempo(measures: 4...7, bpm: 100, in: track, assetID: asset, resolution: .releaseAnchor(b.id))
        let rmap = try TimingMap(track: released.track, assetID: asset)
        let before: Double = 12 * 0.5   // m1–m3 at 120
        let slowed: Double = 16 * 0.6   // m4–m7 at 100
        let after: Double = 36 * 0.5    // m8–m16 at 120
        let expected = 12.4 + before + slowed + after
        XCTAssertEqual(try rmap.audioTime(at: rmap.cursor(measureNumber: 17, beat: 1)), expected, accuracy: 1e-9)
    }

    func testPreserveAudioPinsRefitsWithoutMovingPins() throws {
        let (track, _, _) = try makeAnchored()
        let outcome = try TimingEditor.setTempo(measures: 4...7, bpm: 100, in: track, assetID: asset)
        let map = try TimingMap(track: outcome.track, assetID: asset)
        XCTAssertEqual(try map.audioTime(at: map.cursor(measureNumber: 17, beat: 1)), 44.6, accuracy: 1e-6)
        // The slower measures still take proportionally longer than their neighbours.
        let m4 = try map.audioTime(at: map.cursor(measureNumber: 4, beat: 1))
        let m5 = try map.audioTime(at: map.cursor(measureNumber: 5, beat: 1))
        let m6 = try map.audioTime(at: map.cursor(measureNumber: 6, beat: 1))
        XCTAssertEqual((m6 - m5) / (m5 - m4), 1.2, accuracy: 1e-9)
    }

    func testAnchorRemovalPreview() throws {
        let (track, _, b) = try makeAnchored()
        let before = try TimingMap(track: track, assetID: asset)
        let after = try TimingMap(track: try TimingEditor.removeAnchor(b.id, from: track).track, assetID: asset)
        let preview = TimingEditor.previewChange(from: before, to: after, cursors: [("Set 2", try before.cursor(measureNumber: 17, beat: 1))])
        XCTAssertEqual(preview.first?.before ?? 0, 44.6, accuracy: 1e-9)
        XCTAssertEqual(preview.first?.after ?? 0, 44.4, accuracy: 1e-9)
    }

    func testLocaleIndependentTimeParsing() {
        XCTAssertEqual(TimeFormat.parseClock("00:44.600"), 44.6)
        XCTAssertEqual(TimeFormat.parseClock("44.6 s"), 44.6)
        XCTAssertEqual(TimeFormat.parseClock("1:02:03.5"), 3723.5)
        XCTAssertEqual(TimeFormat.parseClock("-0:01.250"), -1.25)
        XCTAssertNil(TimeFormat.parseClock("44,6"))
        XCTAssertNil(TimeFormat.parseClock("1:75"))
        XCTAssertEqual(TimeFormat.clock(44.6), "00:44.600")
        XCTAssertEqual(TimeFormat.clock(-1.25), "-00:01.250")
        XCTAssertEqual(TimeFormat.decimal(119.25475, places: 3), "119.255")
    }
}
