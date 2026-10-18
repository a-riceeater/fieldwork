import Foundation

/// A notated measure. The measure number is a display label (pickups are
/// numbered 0); identity comes from `id` and order from the track.
public struct Measure: Hashable, Codable, Sendable, Identifiable {
    public var id: MeasureID
    public var number: Int
    public var meter: Meter
    /// Note value the tempo is expressed in (quarter, dotted quarter, ...).
    public var tempoUnit: Rational
    /// Note value of one march count pulse when the meter has no grouping.
    public var pulseUnit: Rational
    /// Pickup measures are shorter than their meter and align pulses to the bar line.
    public var pickupLength: Rational?

    public init(id: MeasureID = MeasureID(), number: Int, meter: Meter, tempoUnit: Rational, pulseUnit: Rational, pickupLength: Rational? = nil) {
        self.id = id
        self.number = number
        self.meter = meter
        self.tempoUnit = tempoUnit
        self.pulseUnit = pulseUnit
        self.pickupLength = pickupLength
    }

    public var length: Rational { pickupLength ?? meter.measureLength }

    /// Offsets (whole-note units from the bar line) where march counts start,
    /// followed by the measure length as the closing boundary.
    public var pulseBoundaries: [Rational] {
        var boundaries: [Rational] = []
        let length = self.length
        if let grouping = meter.grouping, pickupLength == nil {
            var offset = Rational.zero
            for group in grouping {
                boundaries.append(offset)
                offset += meter.beatUnit * Rational(group)
            }
        } else if let pickup = pickupLength {
            // Anacrusis: pulses are counted backwards from the next bar line.
            var offset = pickup
            var reversed: [Rational] = []
            while offset > .zero {
                offset -= pulseUnit
                reversed.append(max(offset, .zero))
            }
            boundaries = reversed.reversed()
        } else {
            var offset = Rational.zero
            while offset < length {
                boundaries.append(offset)
                offset += pulseUnit
            }
        }
        boundaries.append(length)
        return boundaries
    }
}

public enum TimingEventKind: String, Codable, Sendable {
    /// A notated beat that advances notation and (usually) march counts.
    case beat
    /// Elapsed time with no advancing notation or march count (fermata, caesura).
    case hold
}

/// One performance event with stable identity. Beat events carry a notated
/// duration; hold events carry only elapsed time.
public struct TimingEvent: Hashable, Codable, Sendable, Identifiable {
    public var id: EventID
    public var kind: TimingEventKind
    public var measureID: MeasureID
    /// Index of the notated beat inside its measure (0-based). Holds repeat the index of the beat they follow.
    public var beatIndex: Int
    /// Notated duration in whole notes. Zero for holds.
    public var notatedDuration: Rational
    /// Baseline (unfitted) duration in seconds compiled from tempo edits.
    public var baselineSeconds: Double

    public init(id: EventID = EventID(), kind: TimingEventKind, measureID: MeasureID, beatIndex: Int, notatedDuration: Rational, baselineSeconds: Double) {
        self.id = id
        self.kind = kind
        self.measureID = measureID
        self.beatIndex = beatIndex
        self.notatedDuration = notatedDuration
        self.baselineSeconds = baselineSeconds
    }
}

/// How tempo edits treat existing audio pins.
public enum FitMode: String, Codable, Sendable {
    /// Refit elastic durations between pins; pinned timestamps never move.
    case preserveAudioPins
    /// Keep notated tempo; edits inside pinned intervals are conflicts the user must resolve.
    case preserveNotatedTempo
}

/// Binds a musical cursor to an exact sample frame of an audio asset.
public struct AudioAnchor: Hashable, Codable, Sendable, Identifiable {
    public var id: AnchorID
    public var cursor: TimelineCursor
    public var assetID: MediaAssetID
    public var sampleFrame: Int64
    public var sampleRate: Double
    public var locked: Bool

    public init(id: AnchorID = AnchorID(), cursor: TimelineCursor, assetID: MediaAssetID, sampleFrame: Int64, sampleRate: Double, locked: Bool = true) {
        self.id = id
        self.cursor = cursor
        self.assetID = assetID
        self.sampleFrame = sampleFrame
        self.sampleRate = sampleRate
        self.locked = locked
    }

    public var seconds: Double { Double(sampleFrame) / sampleRate }
}

/// A position on the performance timeline: an event plus an exact fraction
/// through it. At boundaries the canonical form is the next event at 0.
public struct TimelineCursor: Hashable, Codable, Sendable, CustomStringConvertible {
    public var eventID: EventID
    public var fraction: Rational

    public init(eventID: EventID, fraction: Rational = .zero) {
        self.eventID = eventID
        self.fraction = fraction
    }

    public var description: String { "\(eventID)@\(fraction)" }
}

public struct TimingError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// The authored musical timeline of one movement: measures, ordered events
/// and audio anchors. Tempo is not stored separately; it is compiled into
/// event baseline durations.
public struct TimingTrack: Hashable, Codable, Sendable {
    public var measures: [Measure]
    public var events: [TimingEvent]
    public var anchors: [AudioAnchor]
    public var fitMode: FitMode

    public init(measures: [Measure] = [], events: [TimingEvent] = [], anchors: [AudioAnchor] = [], fitMode: FitMode = .preserveAudioPins) {
        self.measures = measures
        self.events = events
        self.anchors = anchors
        self.fitMode = fitMode
    }

    /// Builds a constant meter/tempo track.
    /// - Parameters:
    ///   - pickupBeats: number of notated beats in an optional pickup measure numbered 0.
    public static func make(meter: Meter, bpm: Double, tempoUnit: Rational? = nil, pulseUnit: Rational? = nil, measures count: Int, pickupBeats: Int = 0) throws -> TimingTrack {
        var track = TimingTrack()
        if pickupBeats > 0 {
            guard pickupBeats < meter.numerator else { throw TimingError("A pickup must be shorter than a full measure.") }
            try track.appendMeasures(1, meter: meter, bpm: bpm, tempoUnit: tempoUnit, pulseUnit: pulseUnit, pickupBeats: pickupBeats)
        }
        try track.appendMeasures(count, meter: meter, bpm: bpm, tempoUnit: tempoUnit, pulseUnit: pulseUnit)
        return track
    }

    /// Default unit choices: compound meters (6/8, 9/8, 12/8) beat in dotted quarters.
    public static func defaultUnits(for meter: Meter) -> (tempo: Rational, pulse: Rational) {
        if meter.denominator == 8, meter.numerator % 3 == 0, meter.numerator > 3 {
            return (NoteValue.dottedQuarter, NoteValue.dottedQuarter)
        }
        return (meter.beatUnit, meter.beatUnit)
    }

    public static func secondsPerTempoUnit(bpm: Double) -> Double { 60.0 / bpm }

    /// Appends measures with a constant tempo, compiling their baseline durations.
    public mutating func appendMeasures(_ count: Int, meter: Meter, bpm: Double, tempoUnit: Rational? = nil, pulseUnit: Rational? = nil, pickupBeats: Int = 0) throws {
        guard count >= 0 else { throw TimingError("Measure count cannot be negative.") }
        guard meter.isValid else { throw TimingError("Meter \(meter) is not valid.") }
        guard bpm.isFinite, bpm >= 10, bpm <= 500 else { throw TimingError("Tempo must be between 10 and 500 BPM.") }
        let defaults = TimingTrack.defaultUnits(for: meter)
        let tempoUnit = tempoUnit ?? defaults.tempo
        let pulseUnit = pulseUnit ?? defaults.pulse
        guard tempoUnit > .zero, pulseUnit > .zero else { throw TimingError("Tempo and pulse units must be positive.") }
        var nextNumber = (measures.last?.number ?? 0) + 1
        for _ in 0..<count {
            let beats = pickupBeats > 0 ? pickupBeats : meter.numerator
            let measure = Measure(number: pickupBeats > 0 ? 0 : nextNumber, meter: meter, tempoUnit: tempoUnit, pulseUnit: pulseUnit,
                                  pickupLength: pickupBeats > 0 ? meter.beatUnit * Rational(pickupBeats) : nil)
            if pickupBeats == 0 { nextNumber += 1 }
            measures.append(measure)
            for beat in 0..<beats {
                let seconds = (meter.beatUnit / tempoUnit).doubleValue * 60.0 / bpm
                events.append(TimingEvent(kind: .beat, measureID: measure.id, beatIndex: beat, notatedDuration: meter.beatUnit, baselineSeconds: seconds))
            }
        }
    }

    public func eventIndex(of id: EventID) -> Int? { events.firstIndex { $0.id == id } }
    public func measureIndex(of id: MeasureID) -> Int? { measures.firstIndex { $0.id == id } }

    /// Sets a constant tempo for the beat events of the given measure index range.
    public mutating func setTempo(measures range: ClosedRange<Int>, bpm: Double) throws {
        try setTempoRamp(measures: range, startBPM: bpm, endBPM: bpm)
    }

    /// Sets a linear BPM ramp over musical position (in tempo units) across the
    /// measure range, integrated exactly into baseline durations.
    public mutating func setTempoRamp(measures range: ClosedRange<Int>, startBPM: Double, endBPM: Double) throws {
        guard range.lowerBound >= 0, range.upperBound < measures.count else { throw TimingError("Measure range is outside the timeline.") }
        for bpm in [startBPM, endBPM] where !(bpm.isFinite && bpm >= 10 && bpm <= 500) {
            throw TimingError("Tempo must be between 10 and 500 BPM.")
        }
        let ids = Set(measures[range].map(\.id))
        let unitByMeasure = Dictionary(uniqueKeysWithValues: measures[range].map { ($0.id, $0.tempoUnit) })
        let indices = events.indices.filter { ids.contains(events[$0].measureID) && events[$0].kind == .beat }
        let total = indices.reduce(0.0) { $0 + (events[$1].notatedDuration / unitByMeasure[events[$1].measureID]!).doubleValue }
        guard total > 0 else { return }
        let slope = (endBPM - startBPM) / total
        var x = 0.0
        for i in indices {
            let units = (events[i].notatedDuration / unitByMeasure[events[i].measureID]!).doubleValue
            let seconds: Double
            if abs(slope) < 1e-12 {
                seconds = 60.0 * units / startBPM
            } else {
                // ∫ 60 / (a + k x) dx over [x, x + units]
                seconds = 60.0 / slope * log((startBPM + slope * (x + units)) / (startBPM + slope * x))
            }
            events[i].baselineSeconds = seconds
            x += units
        }
    }

    /// Overrides the baseline duration of one event.
    public mutating func setEventDuration(_ id: EventID, seconds: Double) throws {
        guard seconds.isFinite, seconds > 0 else { throw TimingError("Event duration must be positive.") }
        guard let i = eventIndex(of: id) else { throw TimingError("Unknown timing event.") }
        events[i].baselineSeconds = seconds
    }

    /// Inserts a timed hold after the given event.
    @discardableResult
    public mutating func insertHold(after id: EventID, seconds: Double, holdID: EventID = EventID()) throws -> EventID {
        guard seconds.isFinite, seconds > 0 else { throw TimingError("Hold duration must be positive.") }
        guard let i = eventIndex(of: id) else { throw TimingError("Unknown timing event.") }
        let base = events[i]
        events.insert(TimingEvent(id: holdID, kind: .hold, measureID: base.measureID, beatIndex: base.beatIndex, notatedDuration: .zero, baselineSeconds: seconds), at: i + 1)
        return holdID
    }

    /// Notated tempo (BPM in the measure's tempo unit) implied by an event's baseline duration.
    public func baselineTempo(of event: TimingEvent) -> Double? {
        guard event.kind == .beat, let m = measureIndex(of: event.measureID) else { return nil }
        return 60.0 * (event.notatedDuration / measures[m].tempoUnit).doubleValue / event.baselineSeconds
    }

    /// Validates structural invariants of the track.
    public func validate() throws {
        guard !events.isEmpty else { throw TimingError("The timeline has no events.") }
        var seen = Set<EventID>()
        let measureIDs = Set(measures.map(\.id))
        for event in events {
            guard seen.insert(event.id).inserted else { throw TimingError("Duplicate timing event ID.") }
            guard measureIDs.contains(event.measureID) else { throw TimingError("Event references a missing measure.") }
            guard event.baselineSeconds.isFinite, event.baselineSeconds > 0 else { throw TimingError("Event durations must be positive.") }
            if event.kind == .beat { guard event.notatedDuration > .zero else { throw TimingError("Beat events need a notated duration.") } }
        }
        for anchor in anchors where !seen.contains(anchor.cursor.eventID) {
            throw TimingError("Anchor references a missing timing event.")
        }
    }
}
