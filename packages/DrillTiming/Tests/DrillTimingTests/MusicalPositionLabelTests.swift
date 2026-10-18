import XCTest
@testable import DrillTiming

final class MusicalPositionLabelTests: XCTestCase {
    func testPlayheadLabelUsesCompactBeatProgressWithoutChangingTiming() throws {
        let track = try TimingTrack.make(meter: Meter(4, 4), bpm: 120, measures: 24)
        let map = try TimingMap(track: track, assetID: nil)
        let location = map.locate(audioTime: 44.772475)
        let position = try map.musicalPosition(at: location.cursor)

        XCTAssertEqual(position.beatFraction, Rational(35713, 65536))
        XCTAssertEqual(position.label, "m23 b2.54")
        XCTAssertEqual(location.pulse, 89.54495, accuracy: 1e-9)
        XCTAssertEqual(try map.audioTime(at: location.cursor), 44.772475, accuracy: 0.0001)
    }

    func testProgressDoesNotDisplayTheNextBeatBeforeTheBoundary() throws {
        let track = try TimingTrack.make(meter: Meter(4, 4), bpm: 120, measures: 2)
        let map = try TimingMap(track: track, assetID: nil)

        for (time, label) in [(0.0, "m1 b1"), (0.125, "m1 b1.25"),
                              (0.499999, "m1 b1.99"), (0.5, "m1 b2"),
                              (1.999999, "m1 b4.99"), (2.0, "m2 b1"),
                              (4.0, "m2 b4+1")] {
            let position = try map.musicalPosition(at: map.locate(audioTime: time).cursor)
            XCTAssertEqual(position.label, label, "at \(time) seconds")
        }
    }

    func testHoldLabelKeepsTheCompletedBeatAndElapsedTime() throws {
        var track = try TimingTrack.make(meter: Meter(4, 4), bpm: 120, measures: 2)
        let hold = try track.insertHold(after: track.events[3].id, seconds: 2)
        let map = try TimingMap(track: track, assetID: nil)
        let position = try map.musicalPosition(at: TimelineCursor(eventID: hold, fraction: Rational(1, 2)))

        XCTAssertEqual(position.label, "m1 b4+1 hold +1.000 s")
    }
}
