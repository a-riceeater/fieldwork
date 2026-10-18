import Foundation

/// Display form of a cursor: measure number, 1-based beat and the exact
/// fraction through that beat. Inside a hold, `holdOffsetSeconds` is set.
public struct MusicalPosition: Hashable, Sendable {
    public var measureIndex: Int
    public var measureNumber: Int
    public var beat: Int
    public var beatFraction: Rational
    public var holdOffsetSeconds: Double?

    public var label: String {
        var text = "m\(measureNumber) b\(beat)"
        if !beatFraction.isZero { text += "+\(beatFraction)" }
        if let hold = holdOffsetSeconds { text += " hold +\(TimeFormat.seconds(hold))" }
        return text
    }
}

/// Why a set of anchors cannot be satisfied. Contradictions are reported,
/// never silently resolved.
public struct AnchorConflict: Error, Equatable, CustomStringConvertible, Sendable {
    public enum Kind: String, Sendable {
        case duplicateCursor
        case nonMonotonic
        case impliedTempoOutOfRange
        case noElasticTime
    }

    public var kind: Kind
    public var anchors: [AnchorID]
    public var message: String
    public var description: String { message }
}

/// Result of fitting one interval between consecutive anchors.
public struct FitInterval: Equatable, Sendable {
    public var startAnchor: AnchorID
    public var endAnchor: AnchorID
    public var baselineSeconds: Double
    public var fittedSeconds: Double
    /// Common factor applied to elastic (beat) durations in the interval.
    public var scale: Double
    /// Mean fitted tempo in the measures' tempo units, when the interval has beats.
    public var meanTempo: Double?
}

public struct FitReport: Equatable, Sendable {
    /// Audio time of musical position zero (the first event start).
    public var originSeconds: Double
    public var intervals: [FitInterval]
}

/// Where an audio time falls on the timeline.
public struct TimelineLocation: Equatable, Sendable {
    public var cursor: TimelineCursor
    public var pulse: Double
    /// Audio time precedes the first event (pre-roll / silence before the music).
    public var isPreRoll: Bool
    /// Audio time is after the last event.
    public var isPastEnd: Bool
}

/// Compiled, immutable view of a timing track: cursor ↔ notation ↔ count
/// pulses ↔ audio time. All rendering, navigation and export go through it.
public struct TimingMap: Sendable {
    public let track: TimingTrack
    public let assetID: MediaAssetID?
    public let report: FitReport

    private let indexByID: [EventID: Int]
    private let baselineStart: [Double]
    private let offsetInMeasure: [Rational]
    private let measureOfEvent: [Int]
    private let measureStartPulse: [Rational]
    private let boundaries: [[Rational]]
    private let measureEvents: [[Int]]
    private let measureIndexByID: [MeasureID: Int]
    private let knots: [(u: Double, t: Double)]

    /// - Parameter assetID: the movement's selected audio asset. Only anchors on
    ///   that asset constrain the map; with `nil` no anchors apply.
    public init(track: TimingTrack, assetID: MediaAssetID?) throws {
        try track.validate()
        self.track = track
        self.assetID = assetID

        var indexByID: [EventID: Int] = [:]
        var measureIndexByID: [MeasureID: Int] = [:]
        for (i, m) in track.measures.enumerated() { measureIndexByID[m.id] = i }
        var baselineStart = [0.0]
        var offsetInMeasure: [Rational] = []
        var measureOfEvent: [Int] = []
        var measureEvents = Array(repeating: [Int](), count: track.measures.count)
        var runningOffset = Rational.zero
        var lastMeasure = -1
        for (i, event) in track.events.enumerated() {
            indexByID[event.id] = i
            let m = measureIndexByID[event.measureID]!
            if m != lastMeasure {
                guard m > lastMeasure else { throw TimingError("Timing events are out of measure order.") }
                runningOffset = .zero
                lastMeasure = m
            }
            offsetInMeasure.append(runningOffset)
            measureOfEvent.append(m)
            measureEvents[m].append(i)
            runningOffset += event.notatedDuration
            baselineStart.append(baselineStart[i] + event.baselineSeconds)
        }
        var measureStartPulse: [Rational] = [.zero]
        var boundaries: [[Rational]] = []
        for (i, measure) in track.measures.enumerated() {
            let b = measure.pulseBoundaries
            boundaries.append(b)
            measureStartPulse.append(measureStartPulse[i] + Rational(b.count - 1))
        }
        self.indexByID = indexByID
        self.measureIndexByID = measureIndexByID
        self.baselineStart = baselineStart
        self.offsetInMeasure = offsetInMeasure
        self.measureOfEvent = measureOfEvent
        self.measureEvents = measureEvents
        self.measureStartPulse = measureStartPulse
        self.boundaries = boundaries

        let built = try TimingMap.fit(track: track, assetID: assetID, indexByID: indexByID, baselineStart: baselineStart, measureIndexByID: measureIndexByID)
        self.knots = built.knots
        self.report = built.report
    }

    // MARK: Cursor basics

    public var startCursor: TimelineCursor { TimelineCursor(eventID: track.events[0].id) }
    public var endCursor: TimelineCursor { TimelineCursor(eventID: track.events[track.events.count - 1].id, fraction: .one) }
    public var totalPulses: Rational { measureStartPulse[measureStartPulse.count - 1] }
    public var totalBaselineSeconds: Double { baselineStart[baselineStart.count - 1] }

    public func contains(_ cursor: TimelineCursor) -> Bool { indexByID[cursor.eventID] != nil }

    public func eventIndex(_ cursor: TimelineCursor) throws -> Int {
        guard let i = indexByID[cursor.eventID] else { throw TimingError("Cursor references a missing timing event.") }
        guard cursor.fraction >= .zero, cursor.fraction <= .one else { throw TimingError("Cursor fraction must be between 0 and 1.") }
        return i
    }

    /// Canonical form: a fraction of 1 becomes the next event at 0 (except at the very end).
    public func canonical(_ cursor: TimelineCursor) throws -> TimelineCursor {
        let i = try eventIndex(cursor)
        if cursor.fraction == .one, i + 1 < track.events.count {
            return TimelineCursor(eventID: track.events[i + 1].id)
        }
        return cursor
    }

    /// Strict ordering of cursors along the timeline.
    public func compare(_ a: TimelineCursor, _ b: TimelineCursor) throws -> ComparisonResult {
        let ca = try canonical(a), cb = try canonical(b)
        let ia = try eventIndex(ca), ib = try eventIndex(cb)
        if ia != ib { return ia < ib ? .orderedAscending : .orderedDescending }
        if ca.fraction == cb.fraction { return .orderedSame }
        return ca.fraction < cb.fraction ? .orderedAscending : .orderedDescending
    }

    /// Position in baseline seconds (unfitted musical time) from the first event.
    public func baselineSeconds(at cursor: TimelineCursor) throws -> Double {
        let i = try eventIndex(cursor)
        return baselineStart[i] + cursor.fraction.doubleValue * track.events[i].baselineSeconds
    }

    // MARK: Notation and pulses

    /// Continuous march count position (0 = movement start). Holds do not advance counts.
    public func pulse(at cursor: TimelineCursor) throws -> Rational {
        let i = try eventIndex(cursor)
        let event = track.events[i]
        let m = measureOfEvent[i]
        let offset = offsetInMeasure[i] + event.notatedDuration * cursor.fraction
        return measureStartPulse[m] + TimingMap.pulsePosition(offset, boundaries[m])
    }

    static func pulsePosition(_ offset: Rational, _ b: [Rational]) -> Rational {
        if offset >= b[b.count - 1] { return Rational(b.count - 1) }
        var i = 0
        while i + 1 < b.count, b[i + 1] <= offset { i += 1 }
        return Rational(i) + (offset - b[i]) / (b[i + 1] - b[i])
    }

    /// The earliest cursor at a given count position. Integer pulses land on count starts;
    /// a count that begins at a hold resolves to the start of the hold.
    public func cursor(atPulse pulse: Rational) throws -> TimelineCursor {
        guard pulse >= .zero else { throw TimingError("Count positions cannot be negative.") }
        if pulse >= totalPulses { return endCursor }
        var lo = 0, hi = track.measures.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if measureStartPulse[mid] <= pulse { lo = mid } else { hi = mid - 1 }
        }
        let m = lo
        let local = pulse - measureStartPulse[m]
        let b = boundaries[m]
        let whole = Int(local.floor)
        let frac = local - Rational(Int64(whole))
        let offset = b[whole] + frac * (b[whole + 1] - b[whole])
        for e in measureEvents[m] where track.events[e].kind == .beat {
            let start = offsetInMeasure[e]
            let end = start + track.events[e].notatedDuration
            if offset >= start, offset < end {
                var index = e
                let fraction = (offset - start) / track.events[e].notatedDuration
                if fraction.isZero {
                    while index > 0, track.events[index - 1].kind == .hold { index -= 1 }
                }
                return TimelineCursor(eventID: track.events[index].id, fraction: fraction.isZero ? .zero : fraction)
            }
        }
        throw TimingError("Count \(pulse) does not fall on a notated beat.")
    }

    public func cursor(atCount count: Int) throws -> TimelineCursor { try cursor(atPulse: Rational(count)) }

    /// Cursor at the start of a 1-based notated beat in a measure (by display number).
    public func cursor(measureNumber: Int, beat: Int) throws -> TimelineCursor {
        guard let m = track.measures.firstIndex(where: { $0.number == measureNumber }) else {
            throw TimingError("Measure \(measureNumber) does not exist.")
        }
        guard let e = measureEvents[m].first(where: { track.events[$0].kind == .beat && track.events[$0].beatIndex == beat - 1 }) else {
            throw TimingError("Measure \(measureNumber) has no beat \(beat).")
        }
        return TimelineCursor(eventID: track.events[e].id)
    }

    public func musicalPosition(at cursor: TimelineCursor) throws -> MusicalPosition {
        let c = try canonical(cursor)
        var i = try eventIndex(c)
        let event = track.events[i]
        let m = measureOfEvent[i]
        if event.kind == .hold {
            // Describe holds relative to the beat they follow.
            while i > 0, track.events[i].kind == .hold { i -= 1 }
            return MusicalPosition(measureIndex: m, measureNumber: track.measures[m].number, beat: track.events[i].beatIndex + 1,
                                   beatFraction: .one, holdOffsetSeconds: c.fraction.doubleValue * event.baselineSeconds)
        }
        return MusicalPosition(measureIndex: m, measureNumber: track.measures[m].number, beat: event.beatIndex + 1, beatFraction: c.fraction, holdOffsetSeconds: nil)
    }

    public func measure(of cursor: TimelineCursor) throws -> Measure {
        track.measures[measureOfEvent[try eventIndex(cursor)]]
    }

    public func pulseRange(ofMeasure index: Int) -> ClosedRange<Rational> { measureStartPulse[index]...measureStartPulse[index + 1] }

    // MARK: Audio time

    /// Audio time (seconds in the selected asset) of a cursor. Negative values are pre-roll.
    public func audioTime(at cursor: TimelineCursor) throws -> Double {
        TimingMap.forward(try baselineSeconds(at: cursor), knots)
    }

    public func audioTime(atPulse pulse: Rational) throws -> Double { try audioTime(at: cursor(atPulse: pulse)) }

    /// Inverse map: audio time → timeline location (binary search over boundaries).
    public func locate(audioTime t: Double) -> TimelineLocation {
        let u = TimingMap.inverse(t, knots)
        if u <= 0 {
            return TimelineLocation(cursor: startCursor, pulse: 0, isPreRoll: u < 0, isPastEnd: false)
        }
        if u >= totalBaselineSeconds {
            return TimelineLocation(cursor: endCursor, pulse: totalPulses.doubleValue, isPreRoll: false, isPastEnd: u > totalBaselineSeconds)
        }
        var lo = 0, hi = track.events.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if baselineStart[mid] <= u { lo = mid } else { hi = mid - 1 }
        }
        let event = track.events[lo]
        let fraction = (u - baselineStart[lo]) / event.baselineSeconds
        let m = measureOfEvent[lo]
        let offset = offsetInMeasure[lo].doubleValue + event.notatedDuration.doubleValue * fraction
        let pulse = measureStartPulse[m].doubleValue + TimingMap.pulsePosition(offset, boundaries[m])
        // Cursor fractions are rational; quantize to 1/65536 of an event (well under 0.1 ms for typical events).
        let steps: Int64 = 65_536
        let q = Rational(min(Int64((fraction * Double(steps)).rounded(.down)), steps - 1), steps)
        return TimelineLocation(cursor: TimelineCursor(eventID: event.id, fraction: q), pulse: pulse, isPreRoll: false, isPastEnd: false)
    }

    static func pulsePosition(_ offset: Double, _ b: [Rational]) -> Double {
        let last = b[b.count - 1].doubleValue
        if offset >= last { return Double(b.count - 1) }
        var i = 0
        while i + 1 < b.count, b[i + 1].doubleValue <= offset { i += 1 }
        let start = b[i].doubleValue
        return Double(i) + (offset - start) / (b[i + 1].doubleValue - start)
    }

    // MARK: Fitting

    static func forward(_ u: Double, _ knots: [(u: Double, t: Double)]) -> Double {
        guard let first = knots.first, let last = knots.last else { return u }
        if u <= first.u { return first.t + (u - first.u) }
        if u >= last.u { return last.t + (u - last.u) }
        var lo = 0, hi = knots.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if knots[mid].u <= u { lo = mid } else { hi = mid }
        }
        let a = knots[lo], b = knots[hi]
        return a.t + (u - a.u) * (b.t - a.t) / (b.u - a.u)
    }

    static func inverse(_ t: Double, _ knots: [(u: Double, t: Double)]) -> Double {
        guard let first = knots.first, let last = knots.last else { return t }
        if t <= first.t { return first.u + (t - first.t) }
        if t >= last.t { return last.u + (t - last.t) }
        var lo = 0, hi = knots.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if knots[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = knots[lo], b = knots[hi]
        return a.u + (t - a.t) * (b.u - a.u) / (b.t - a.t)
    }

    /// Allowed range of the common duration scale inside a pinned interval.
    public static let allowedScale: ClosedRange<Double> = (1.0 / 3.0)...3.0

    private static func fit(track: TimingTrack, assetID: MediaAssetID?, indexByID: [EventID: Int], baselineStart: [Double],
                            measureIndexByID: [MeasureID: Int]) throws -> (knots: [(u: Double, t: Double)], report: FitReport) {
        guard let assetID else { return ([], FitReport(originSeconds: 0, intervals: [])) }
        func u(_ c: TimelineCursor) -> Double {
            let i = indexByID[c.eventID]!
            return baselineStart[i] + c.fraction.doubleValue * track.events[i].baselineSeconds
        }
        let anchors = track.anchors.filter { $0.assetID == assetID }.sorted { u($0.cursor) < u($1.cursor) }
        guard let firstAnchor = anchors.first else { return ([], FitReport(originSeconds: 0, intervals: [])) }
        var knots: [(u: Double, t: Double)] = [(u(firstAnchor.cursor), firstAnchor.seconds)]
        var intervals: [FitInterval] = []
        for (a, b) in zip(anchors, anchors.dropFirst()) {
            let ua = u(a.cursor), ub = u(b.cursor)
            if abs(ub - ua) < 1e-12 {
                throw AnchorConflict(kind: .duplicateCursor, anchors: [a.id, b.id], message: "Two anchors pin the same musical position.")
            }
            let elapsed = b.seconds - a.seconds
            guard elapsed > 0 else {
                throw AnchorConflict(kind: .nonMonotonic, anchors: [a.id, b.id],
                                     message: "Anchors must move forward in both music and audio; a later musical position is pinned at an earlier or equal timestamp.")
            }
            let ia = indexByID[a.cursor.eventID]!, ib = indexByID[b.cursor.eventID]!
            var elastic = 0.0, fixed = 0.0, tempoUnits = 0.0
            for i in ia...min(ib, track.events.count - 1) {
                let start = baselineStart[i], end = baselineStart[i + 1]
                let overlap = min(end, ub) - max(start, ua)
                guard overlap > 0 else { continue }
                let event = track.events[i]
                if event.kind == .hold { fixed += overlap } else {
                    elastic += overlap
                    let unit = track.measures[measureIndexByID[event.measureID]!].tempoUnit
                    tempoUnits += (event.notatedDuration / unit).doubleValue * overlap / event.baselineSeconds
                }
            }
            guard elastic > 0, elapsed - fixed > 0 else {
                throw AnchorConflict(kind: .noElasticTime, anchors: [a.id, b.id],
                                     message: "The pinned interval has no beat time left to fit after fixed holds.")
            }
            let scale = (elapsed - fixed) / elastic
            guard allowedScale.contains(scale) else {
                let tempo = 60.0 * tempoUnits / (elapsed - fixed)
                throw AnchorConflict(kind: .impliedTempoOutOfRange, anchors: [a.id, b.id],
                                     message: String(format: "These anchors imply a mean tempo of %.1f BPM (%.2f× the notated durations), outside the supported fitting range.", tempo, 1 / scale))
            }
            var t = a.seconds
            for i in ia...min(ib, track.events.count - 1) {
                let start = max(baselineStart[i], ua), end = min(baselineStart[i + 1], ub)
                guard end > start else { continue }
                t += (end - start) * (track.events[i].kind == .hold ? 1 : scale)
                if end > knots[knots.count - 1].u { knots.append((end, t)) }
            }
            // Guard against floating drift so the knot lands exactly on the anchor.
            knots[knots.count - 1] = (ub, b.seconds)
            intervals.append(FitInterval(startAnchor: a.id, endAnchor: b.id, baselineSeconds: elastic + fixed, fittedSeconds: elapsed, scale: scale,
                                         meanTempo: tempoUnits > 0 ? 60.0 * tempoUnits / (elapsed - fixed) : nil))
        }
        let origin = forward(0, knots)
        return (knots, FitReport(originSeconds: origin, intervals: intervals))
    }
}
