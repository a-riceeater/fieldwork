import XCTest
@testable import DrillTiming

final class TimingMapTests: XCTestCase {
    let asset = MediaAssetID()
    let rate = 48_000.0

    func frame(_ seconds: Double) -> Int64 { Int64((seconds * rate).rounded()) }

    func anchor(_ map: TimingMap, measure: Int, beat: Int = 1, at seconds: Double) throws -> AudioAnchor {
        AudioAnchor(cursor: try map.cursor(measureNumber: measure, beat: beat), assetID: asset, sampleFrame: frame(seconds), sampleRate: rate)
    }

    // The architecture's acceptance example: 4/4, quarter = 120, m1 b1 pinned at 12.400 s.
    func testSecondPinRefitsArrivalFrom44_400To44_600() throws {
        var track = try TimingTrack.make(meter: Meter(4, 4), bpm: 120, measures: 24)
        var map = try TimingMap(track: track, assetID: asset)
        let arrival = try map.cursor(measureNumber: 17, beat: 1)
        let arrivalPulseBefore = try map.pulse(at: arrival)

        track = try TimingEditor.addAnchor(try anchor(map, measure: 1, at: 12.4), to: track).track
        map = try TimingMap(track: track, assetID: asset)
        XCTAssertEqual(try map.audioTime(at: arrival), 44.4, accuracy: 1e-9, "one anchor = offset only")

        let second = try anchor(map, measure: 17, at: 44.4)
        track = try TimingEditor.addAnchor(second, to: track).track
        map = try TimingMap(track: track, assetID: asset)
        XCTAssertEqual(try map.audioTime(at: arrival), 44.4, accuracy: 1e-9)

        // Change the second pin to 44.600 s.
        let outcome = try TimingEditor.moveAnchor(second.id, toSampleFrame: frame(44.6), in: track)
        map = try TimingMap(track: outcome.track, assetID: asset)
        XCTAssertEqual(try map.audioTime(at: arrival), 44.6, accuracy: 1e-9)
        XCTAssertEqual(try map.pulse(at: arrival), arrivalPulseBefore, "musical position is unchanged")
        XCTAssertEqual(try map.musicalPosition(at: arrival).label, "m17 b1")

        let fit = try XCTUnwrap(outcome.report.intervals.first)
        XCTAssertEqual(fit.scale, 1.00625, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(fit.meanTempo), 119.2547, accuracy: 1e-3)
        // Beyond the last pin, baseline durations continue from the nearest anchor.
        let m18 = try map.cursor(measureNumber: 18, beat: 1)
        XCTAssertEqual(try map.audioTime(at: m18), 46.6, accuracy: 1e-9)
        // Before the first pin, baseline durations: position 0 is m1 b1 here.
        XCTAssertEqual(outcome.report.originSeconds, 12.4, accuracy: 1e-9)
    }

    func testInverseMapRoundTripsAcrossFittedAndHoldRegions() throws {
        var track = try TimingTrack.make(meter: Meter(4, 4), bpm: 120, measures: 12)
        let holdAfter = track.events[15].id // m4 b4
        try track.insertHold(after: holdAfter, seconds: 2.5)
        var map = try TimingMap(track: track, assetID: asset)
        track = try TimingEditor.addAnchor(try anchor(map, measure: 1, at: 3.0), to: track).track
        map = try TimingMap(track: track, assetID: asset)
        track = try TimingEditor.addAnchor(try anchor(map, measure: 9, at: 3.0 + 16.0 + 2.5 + 0.8), to: track).track
        map = try TimingMap(track: track, assetID: asset)

        var previous = -Double.infinity
        for t in stride(from: 0.0, through: 30.0, by: 0.037) {
            let location = map.locate(audioTime: t)
            XCTAssertGreaterThanOrEqual(location.pulse, previous - 1e-9, "count position is monotonic")
            previous = location.pulse
            if !location.isPreRoll && !location.isPastEnd {
                let back = try map.audioTime(at: location.cursor)
                XCTAssertEqual(back, t, accuracy: 0.0001, "inverse within cursor quantization")
            }
        }
        // The hold keeps the count constant while time advances by exactly its fixed duration.
        let fit = try XCTUnwrap(map.report.intervals.first)
        XCTAssertEqual(fit.scale, (16.0 + 0.8) / 16.0, accuracy: 1e-9)
        let holdStart = try map.audioTime(at: TimelineCursor(eventID: track.events[16].id))
        let holdEnd = try map.audioTime(at: TimelineCursor(eventID: track.events[17].id))
        XCTAssertEqual(holdEnd - holdStart, 2.5, accuracy: 1e-9)
        XCTAssertEqual(map.locate(audioTime: holdStart + 1).pulse, 16, accuracy: 1e-9)
    }

    func testPreRollIsNotANegativeSeek() throws {
        var track = try TimingTrack.make(meter: Meter(4, 4), bpm: 120, measures: 4)
        let map = try TimingMap(track: track, assetID: asset)
        track = try TimingEditor.addAnchor(try anchor(map, measure: 1, at: 2.0), to: track).track
        let fitted = try TimingMap(track: track, assetID: asset)
        let early = fitted.locate(audioTime: 0.5)
        XCTAssertTrue(early.isPreRoll)
        XCTAssertEqual(early.pulse, 0)
        // Anchoring a later bar near the start yields a negative origin (music starts before the file).
        var track2 = try TimingTrack.make(meter: Meter(4, 4), bpm: 120, measures: 4)
        let map2 = try TimingMap(track: track2, assetID: asset)
        track2 = try TimingEditor.addAnchor(try anchor(map2, measure: 2, at: 1.0), to: track2).track
        XCTAssertEqual(try TimingMap(track: track2, assetID: asset).report.originSeconds, -1.0, accuracy: 1e-9)
    }

    func testCompoundMeterPulseIsExplicit() throws {
        // 6/8 at dotted quarter = 80: 1.5 s per bar, two march counts per bar by default.
        let track = try TimingTrack.make(meter: Meter(6, 8), bpm: 80, measures: 4)
        let map = try TimingMap(track: track, assetID: nil)
        XCTAssertEqual(map.totalPulses, Rational(8))
        let m2 = try map.cursor(measureNumber: 2, beat: 1)
        XCTAssertEqual(try map.audioTime(at: m2), 1.5, accuracy: 1e-9)
        XCTAssertEqual(try map.pulse(at: m2), Rational(2))
        let m1b4 = try map.cursor(measureNumber: 1, beat: 4)
        XCTAssertEqual(try map.pulse(at: m1b4), Rational(1))

        // The same notation counted in six (eighth-note pulse) has six counts per bar.
        let six = try TimingTrack.make(meter: Meter(6, 8), bpm: 80, tempoUnit: NoteValue.dottedQuarter, pulseUnit: NoteValue.eighth, measures: 4)
        let sixMap = try TimingMap(track: six, assetID: nil)
        XCTAssertEqual(sixMap.totalPulses, Rational(24))
        XCTAssertEqual(try sixMap.audioTime(at: sixMap.cursor(measureNumber: 2, beat: 1)), 1.5, accuracy: 1e-9)
    }

    func testIrregularGroupingDefinesCounts() throws {
        let track = try TimingTrack.make(meter: Meter(5, 8, grouping: [3, 2]), bpm: 240, tempoUnit: NoteValue.eighth, pulseUnit: NoteValue.eighth, measures: 2)
        let map = try TimingMap(track: track, assetID: nil)
        XCTAssertEqual(map.totalPulses, Rational(4))
        let count1 = try map.cursor(atCount: 1)
        XCTAssertEqual(try map.musicalPosition(at: count1).beat, 4)
        // Halfway through the 2-eighth group is half a count.
        let mid = try map.cursor(measureNumber: 1, beat: 5)
        XCTAssertEqual(try map.pulse(at: mid), Rational(3, 2))
    }

    func testPickupMeasureNumberingAndCounts() throws {
        let track = try TimingTrack.make(meter: Meter(4, 4), bpm: 120, measures: 4, pickupBeats: 1)
        let map = try TimingMap(track: track, assetID: nil)
        XCTAssertEqual(track.measures.first?.number, 0)
        XCTAssertEqual(track.measures[1].number, 1)
        let m1 = try map.cursor(measureNumber: 1, beat: 1)
        XCTAssertEqual(try map.pulse(at: m1), Rational(1))
        XCTAssertEqual(try map.audioTime(at: m1), 0.5, accuracy: 1e-9)
    }

    func testCountCursorInHoldResolvesToHoldStart() throws {
        var track = try TimingTrack.make(meter: Meter(4, 4), bpm: 120, measures: 4)
        let holdID = try track.insertHold(after: track.events[3].id, seconds: 1.0)
        let map = try TimingMap(track: track, assetID: nil)
        let c = try map.cursor(atCount: 4)
        XCTAssertEqual(c.eventID, holdID)
        XCTAssertEqual(try map.musicalPosition(at: TimelineCursor(eventID: holdID, fraction: Rational(1, 2))).holdOffsetSeconds, 0.5)
    }

    func testTempoRampIntegratesConsistently() throws {
        var track = try TimingTrack.make(meter: Meter(4, 4), bpm: 120, measures: 4)
        try track.setTempoRamp(measures: 0...3, startBPM: 100, endBPM: 140)
        let total = track.events.reduce(0) { $0 + $1.baselineSeconds }
        // ∫_0^16 60 / (100 + 2.5x) dx
        XCTAssertEqual(total, 60 / 2.5 * log(140.0 / 100.0), accuracy: 1e-9)
        XCTAssertGreaterThan(track.events[0].baselineSeconds, track.events[15].baselineSeconds)
    }

    func testCursorCanonicalization() throws {
        let track = try TimingTrack.make(meter: Meter(4, 4), bpm: 120, measures: 2)
        let map = try TimingMap(track: track, assetID: nil)
        let end = TimelineCursor(eventID: track.events[2].id, fraction: .one)
        XCTAssertEqual(try map.canonical(end), TimelineCursor(eventID: track.events[3].id))
        XCTAssertEqual(try map.compare(end, TimelineCursor(eventID: track.events[3].id)), .orderedSame)
        XCTAssertEqual(try map.canonical(map.endCursor), map.endCursor)
    }

    func testRationalArithmetic() {
        XCTAssertEqual(Rational(1, 4) + Rational(1, 8), Rational(3, 8))
        XCTAssertEqual(Rational(3, 8) / Rational(1, 8), Rational(3))
        XCTAssertEqual(Rational(-2, -4), Rational(1, 2))
        XCTAssertEqual(Rational(-7, 2).floor, -4)
        XCTAssertLessThan(Rational(1, 3), Rational(1, 2))
    }
}
