import Foundation
import DrillTiming
import DrillCore

/// The `show.sqlite` schema and its original repositories. Coordinates are
/// meters, angles degrees, times seconds or sample frames, rationals stored as
/// numerator/denominator integer pairs.
enum ShowDatabase {
    static let currentSchemaVersion = 2

    static let schemaV1 = """
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE show (id TEXT PRIMARY KEY, title TEXT NOT NULL, max_stride REAL NOT NULL, min_clearance REAL NOT NULL);
    CREATE TABLE field (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), name TEXT NOT NULL, preset TEXT NOT NULL,
        length REAL NOT NULL, width REAL NOT NULL, step_size REAL NOT NULL, side_labels TEXT NOT NULL,
        front_label TEXT NOT NULL, back_label TEXT NOT NULL);
    CREATE TABLE field_checkpoint (ordinal INTEGER PRIMARY KEY, axis TEXT NOT NULL CHECK (axis IN ('x','y')),
        position REAL NOT NULL, label TEXT NOT NULL, prominence TEXT NOT NULL);
    CREATE TABLE media_asset (id TEXT PRIMARY KEY, sha256 TEXT NOT NULL, extension TEXT NOT NULL, original_filename TEXT NOT NULL,
        byte_count INTEGER NOT NULL, sample_rate REAL NOT NULL, frame_count INTEGER NOT NULL, channel_count INTEGER NOT NULL);
    CREATE TABLE section (id TEXT PRIMARY KEY, ordinal INTEGER NOT NULL, name TEXT NOT NULL, prefix TEXT NOT NULL,
        symbol TEXT NOT NULL, color_index INTEGER NOT NULL);
    CREATE TABLE performer (id TEXT PRIMARY KEY, ordinal INTEGER NOT NULL, label TEXT NOT NULL UNIQUE,
        section_id TEXT NOT NULL REFERENCES section(id), name TEXT, notes TEXT NOT NULL);
    CREATE TABLE movement (id TEXT PRIMARY KEY, ordinal INTEGER NOT NULL, name TEXT NOT NULL,
        audio_asset_id TEXT REFERENCES media_asset(id), fit_mode TEXT NOT NULL);
    CREATE TABLE measure (id TEXT PRIMARY KEY, movement_id TEXT NOT NULL REFERENCES movement(id), ordinal INTEGER NOT NULL,
        number INTEGER NOT NULL, meter_numerator INTEGER NOT NULL, meter_denominator INTEGER NOT NULL, grouping TEXT,
        tempo_unit_num INTEGER NOT NULL, tempo_unit_den INTEGER NOT NULL, pulse_unit_num INTEGER NOT NULL, pulse_unit_den INTEGER NOT NULL,
        pickup_num INTEGER, pickup_den INTEGER);
    CREATE TABLE timing_event (id TEXT PRIMARY KEY, movement_id TEXT NOT NULL REFERENCES movement(id), ordinal INTEGER NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN ('beat','hold')), measure_id TEXT NOT NULL REFERENCES measure(id), beat_index INTEGER NOT NULL,
        notated_num INTEGER NOT NULL, notated_den INTEGER NOT NULL, baseline_seconds REAL NOT NULL CHECK (baseline_seconds > 0));
    CREATE TABLE audio_anchor (id TEXT PRIMARY KEY, movement_id TEXT NOT NULL REFERENCES movement(id),
        event_id TEXT NOT NULL REFERENCES timing_event(id), fraction_num INTEGER NOT NULL, fraction_den INTEGER NOT NULL,
        asset_id TEXT NOT NULL REFERENCES media_asset(id), sample_frame INTEGER NOT NULL, sample_rate REAL NOT NULL, locked INTEGER NOT NULL);
    CREATE TABLE arrival_set (id TEXT PRIMARY KEY, movement_id TEXT NOT NULL REFERENCES movement(id), ordinal INTEGER NOT NULL,
        label TEXT NOT NULL, event_id TEXT NOT NULL REFERENCES timing_event(id), fraction_num INTEGER NOT NULL, fraction_den INTEGER NOT NULL,
        is_subset INTEGER NOT NULL, notes TEXT NOT NULL);
    CREATE TABLE transition (id TEXT PRIMARY KEY, to_set_id TEXT NOT NULL UNIQUE REFERENCES arrival_set(id), model TEXT NOT NULL);
    CREATE TABLE placement (set_id TEXT NOT NULL REFERENCES arrival_set(id), performer_id TEXT NOT NULL REFERENCES performer(id),
        state TEXT NOT NULL CHECK (state IN ('placed','unresolved','inactive')), x REAL, y REAL, z REAL, facing REAL,
        PRIMARY KEY (set_id, performer_id));
    CREATE TABLE form (id TEXT PRIMARY KEY, set_id TEXT NOT NULL REFERENCES arrival_set(id), ordinal INTEGER NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN ('line','arc')), x0 REAL NOT NULL, y0 REAL NOT NULL, x1 REAL NOT NULL, y1 REAL NOT NULL, bulge REAL NOT NULL);
    CREATE TABLE form_member (form_id TEXT NOT NULL REFERENCES form(id), ordinal INTEGER NOT NULL,
        performer_id TEXT NOT NULL REFERENCES performer(id), PRIMARY KEY (form_id, ordinal));
    """

    /// Schema 2: counting mode on the show, rehearsal mark and measure marker on sets.
    static let schemaV2Changes = """
    ALTER TABLE show ADD COLUMN counting_mode TEXT NOT NULL DEFAULT 'measures' CHECK (counting_mode IN ('measures','counts'));
    ALTER TABLE arrival_set ADD COLUMN rehearsal_mark TEXT NOT NULL DEFAULT '';
    ALTER TABLE arrival_set ADD COLUMN measure_marker TEXT NOT NULL DEFAULT '';
    """

    /// Ordered upgrade steps: `migrations[v]` upgrades schema v to v + 1.
    typealias Migration = @Sendable (SQLiteDatabase) throws -> Void
    static let migrations: [Int: Migration] = [1: { db in try db.execute(schemaV2Changes) }]

    /// Upgrades an in-memory copy. The original archive bytes are never touched.
    static func migrate(_ db: SQLiteDatabase, to target: Int = currentSchemaVersion, using steps: [Int: Migration] = migrations) throws {
        var version = db.userVersion
        guard version <= target else { throw DocumentError.newerSchema(version) }
        while version < target {
            guard let step = steps[version] else { throw DocumentError.corrupt("No migration from schema version \(version).") }
            try db.transaction {
                try step(db)
                try db.setUserVersion(version + 1)
            }
            version += 1
        }
    }

    // MARK: Writing

    static func encode(_ show: Show, writer: String) throws -> Data {
        let db = try SQLiteDatabase()
        try db.transaction {
            try db.execute(schemaV1)
            try db.execute(schemaV2Changes)
            try db.setUserVersion(currentSchemaVersion)
            let meta = try db.prepare("INSERT INTO meta (key, value) VALUES (?, ?)")
            try meta.run([.text("writer"), .text(writer)])
            try meta.run([.text("units"), .text("meters")])
            try db.prepare("INSERT INTO show (id, title, max_stride, min_clearance, counting_mode) VALUES (?, ?, ?, ?, ?)").run([.text(show.id.description), .text(show.title),
                                                                         .double(show.analysis.maxStride), .double(show.analysis.minClearance), .text(show.countingMode.rawValue)])
            let f = show.field
            let sideLabels = String(data: try JSONEncoder().encode(f.sideLabels), encoding: .utf8)!
            try db.prepare("INSERT INTO field VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?)").run([
                .text(f.name), .text(f.preset.rawValue), .double(f.length), .double(f.width), .double(f.stepSize), .text(sideLabels),
                .text(f.frontLabel), .text(f.backLabel)])
            let cp = try db.prepare("INSERT INTO field_checkpoint VALUES (?, ?, ?, ?, ?)")
            for (i, c) in f.checkpoints.enumerated() {
                try cp.run([.int(i), .text(c.axis.rawValue), .double(c.position), .text(c.label), .text(c.prominence.rawValue)])
            }
            let asset = try db.prepare("INSERT INTO media_asset VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
            for a in show.mediaAssets {
                try asset.run([.text(a.id.description), .text(a.sha256), .text(a.fileExtension), .text(a.originalFilename),
                               .int(a.byteCount), .double(a.sampleRate), .int(a.frameCount), .int(a.channelCount)])
            }
            let section = try db.prepare("INSERT INTO section VALUES (?, ?, ?, ?, ?, ?)")
            for (i, s) in show.sections.enumerated() {
                try section.run([.text(s.id.description), .int(i), .text(s.name), .text(s.prefix), .text(s.symbol.rawValue), .int(s.colorIndex)])
            }
            let performer = try db.prepare("INSERT INTO performer VALUES (?, ?, ?, ?, ?, ?)")
            for (i, p) in show.performers.enumerated() {
                try performer.run([.text(p.id.description), .int(i), .text(p.label), .text(p.sectionID.description), .optional(p.name), .text(p.notes)])
            }
            let movement = try db.prepare("INSERT INTO movement VALUES (?, ?, ?, ?, ?)")
            let measure = try db.prepare("INSERT INTO measure VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
            let event = try db.prepare("INSERT INTO timing_event VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
            let anchor = try db.prepare("INSERT INTO audio_anchor VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
            for (i, m) in show.movements.enumerated() {
                try movement.run([.text(m.id.description), .int(i), .text(m.name), .optional(m.audioAssetID?.description), .text(m.timing.fitMode.rawValue)])
                for (j, ms) in m.timing.measures.enumerated() {
                    let grouping = ms.meter.grouping.map { $0.map(String.init).joined(separator: "+") }
                    try measure.run([.text(ms.id.description), .text(m.id.description), .int(j), .int(ms.number), .int(ms.meter.numerator),
                                     .int(ms.meter.denominator), .optional(grouping), .int(ms.tempoUnit.numerator), .int(ms.tempoUnit.denominator),
                                     .int(ms.pulseUnit.numerator), .int(ms.pulseUnit.denominator),
                                     ms.pickupLength.map { .int($0.numerator) } ?? .null, ms.pickupLength.map { .int($0.denominator) } ?? .null])
                }
                for (j, e) in m.timing.events.enumerated() {
                    try event.run([.text(e.id.description), .text(m.id.description), .int(j), .text(e.kind.rawValue), .text(e.measureID.description),
                                   .int(e.beatIndex), .int(e.notatedDuration.numerator), .int(e.notatedDuration.denominator), .double(e.baselineSeconds)])
                }
                for a in m.timing.anchors {
                    try anchor.run([.text(a.id.description), .text(m.id.description), .text(a.cursor.eventID.description), .int(a.cursor.fraction.numerator),
                                    .int(a.cursor.fraction.denominator), .text(a.assetID.description), .int(a.sampleFrame), .double(a.sampleRate), .bool(a.locked)])
                }
            }
            let set = try db.prepare("INSERT INTO arrival_set VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
            for (i, s) in show.sets.enumerated() {
                try set.run([.text(s.id.description), .text(s.movementID.description), .int(i), .text(s.label), .text(s.cursor.eventID.description),
                             .int(s.cursor.fraction.numerator), .int(s.cursor.fraction.denominator), .bool(s.isSubset), .text(s.notes),
                             .text(s.rehearsalMark), .text(s.measureMarker)])
            }
            let transition = try db.prepare("INSERT INTO transition VALUES (?, ?, ?)")
            for t in show.transitions { try transition.run([.text(t.id.description), .text(t.toSetID.description), .text(t.model.rawValue)]) }
            let placement = try db.prepare("INSERT INTO placement VALUES (?, ?, ?, ?, ?, ?, ?)")
            for s in show.sets {
                let formation = show.formation(s.id)
                for p in show.performers {
                    guard let value = formation.placements[p.id] else { continue }
                    switch value {
                    case .placed(let pos):
                        try placement.run([.text(s.id.description), .text(p.id.description), .text("placed"), .double(pos.x), .double(pos.y), .double(pos.z), .double(pos.facing)])
                    case .unresolved:
                        try placement.run([.text(s.id.description), .text(p.id.description), .text("unresolved"), .null, .null, .null, .null])
                    case .inactive:
                        try placement.run([.text(s.id.description), .text(p.id.description), .text("inactive"), .null, .null, .null, .null])
                    }
                }
            }
            let form = try db.prepare("INSERT INTO form VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
            let member = try db.prepare("INSERT INTO form_member VALUES (?, ?, ?)")
            for (i, fm) in show.forms.enumerated() {
                let (start, end) = fm.geometry.endpoints
                var kind = "line", bulge = 0.0
                if case .arc(_, _, let b) = fm.geometry { kind = "arc"; bulge = b }
                try form.run([.text(fm.id.description), .text(fm.setID.description), .int(i), .text(kind), .double(start.x), .double(start.y),
                              .double(end.x), .double(end.y), .double(bulge)])
                for (j, m) in fm.members.enumerated() { try member.run([.text(fm.id.description), .int(j), .text(m.description)]) }
            }
            let violations = try db.prepare("PRAGMA foreign_key_check")
            if try violations.step() { throw DocumentError.corrupt("The show has broken references (\(violations.text(0))).") }
        }
        return try db.serialize()
    }

    // MARK: Reading

    static func decode(_ bytes: Data) throws -> Show {
        let db = try SQLiteDatabase(bytes: bytes)
        try migrate(db)
        return try read(db)
    }

    static func id<T>(_ s: String, _ type: TypedID<T>.Type) throws -> TypedID<T> {
        guard let id = TypedID<T>(s) else { throw DocumentError.corrupt("Invalid identifier \(s).") }
        return id
    }

    static func rational(_ n: Int64, _ d: Int64) throws -> Rational {
        guard d > 0 else { throw DocumentError.corrupt("Invalid rational value.") }
        return Rational(n, d)
    }

    static func read(_ db: SQLiteDatabase) throws -> Show {
        let showRow = try db.prepare("SELECT id, title, max_stride, min_clearance, counting_mode FROM show")
        guard try showRow.step() else { throw DocumentError.corrupt("The show record is missing.") }
        let showID = try id(showRow.text(0), ShowID.self)
        let title = showRow.text(1)
        let analysis = AnalysisSettings(maxStride: showRow.double(2), minClearance: showRow.double(3))
        guard let countingMode = CountingMode(rawValue: showRow.text(4)) else { throw DocumentError.corrupt("Unknown counting mode.") }

        let fieldRow = try db.prepare("SELECT name, preset, length, width, step_size, side_labels, front_label, back_label FROM field")
        guard try fieldRow.step() else { throw DocumentError.corrupt("The field record is missing.") }
        var checkpoints: [Checkpoint] = []
        let cp = try db.prepare("SELECT axis, position, label, prominence FROM field_checkpoint ORDER BY ordinal")
        while try cp.step() {
            guard let axis = Checkpoint.Axis(rawValue: cp.text(0)), let prominence = Checkpoint.Prominence(rawValue: cp.text(3)) else {
                throw DocumentError.corrupt("Unknown field checkpoint type.")
            }
            checkpoints.append(Checkpoint(axis: axis, position: cp.double(1), label: cp.text(2), prominence: prominence))
        }
        let sideLabels = try JSONDecoder().decode([String].self, from: Data(fieldRow.text(5).utf8))
        let field = Field(name: fieldRow.text(0), preset: Field.Preset(rawValue: fieldRow.text(1)) ?? .custom, length: fieldRow.double(2),
                          width: fieldRow.double(3), stepSize: fieldRow.double(4), checkpoints: checkpoints, sideLabels: sideLabels,
                          frontLabel: fieldRow.text(6), backLabel: fieldRow.text(7))

        var assets: [MediaAssetInfo] = []
        let asset = try db.prepare("SELECT id, sha256, extension, original_filename, byte_count, sample_rate, frame_count, channel_count FROM media_asset ORDER BY rowid")
        while try asset.step() {
            assets.append(MediaAssetInfo(id: try id(asset.text(0), MediaAssetID.self), sha256: asset.text(1), fileExtension: asset.text(2),
                                         originalFilename: asset.text(3), byteCount: asset.int64(4), sampleRate: asset.double(5),
                                         frameCount: asset.int64(6), channelCount: asset.int(7)))
        }

        var sections: [Section] = []
        let section = try db.prepare("SELECT id, name, prefix, symbol, color_index FROM section ORDER BY ordinal")
        while try section.step() {
            sections.append(Section(id: try id(section.text(0), SectionID.self), name: section.text(1), prefix: section.text(2),
                                    symbol: PerformerSymbol(rawValue: section.text(3)) ?? .circle, colorIndex: section.int(4)))
        }
        var performers: [Performer] = []
        let performer = try db.prepare("SELECT id, label, section_id, name, notes FROM performer ORDER BY ordinal")
        while try performer.step() {
            performers.append(Performer(id: try id(performer.text(0), PerformerID.self), label: performer.text(1),
                                        sectionID: try id(performer.text(2), SectionID.self), name: performer.optionalText(3), notes: performer.text(4)))
        }

        var movements: [Movement] = []
        let movement = try db.prepare("SELECT id, name, audio_asset_id, fit_mode FROM movement ORDER BY ordinal")
        let measure = try db.prepare("""
            SELECT id, number, meter_numerator, meter_denominator, grouping, tempo_unit_num, tempo_unit_den, pulse_unit_num, pulse_unit_den,
            pickup_num, pickup_den FROM measure WHERE movement_id = ? ORDER BY ordinal
            """)
        let event = try db.prepare("SELECT id, kind, measure_id, beat_index, notated_num, notated_den, baseline_seconds FROM timing_event WHERE movement_id = ? ORDER BY ordinal")
        let anchor = try db.prepare("SELECT id, event_id, fraction_num, fraction_den, asset_id, sample_frame, sample_rate, locked FROM audio_anchor WHERE movement_id = ? ORDER BY rowid")
        while try movement.step() {
            let movementID = try id(movement.text(0), MovementID.self)
            var track = TimingTrack(fitMode: FitMode(rawValue: movement.text(3)) ?? .preserveAudioPins)
            try measure.bind([.text(movementID.description)])
            while try measure.step() {
                let grouping = measure.optionalText(4).map { $0.split(separator: "+").compactMap { Int($0) } }
                let pickup = measure.isNull(9) ? nil : try rational(measure.int64(9), measure.int64(10))
                track.measures.append(Measure(id: try id(measure.text(0), MeasureID.self), number: measure.int(1),
                                              meter: Meter(measure.int(2), measure.int(3), grouping: grouping),
                                              tempoUnit: try rational(measure.int64(5), measure.int64(6)),
                                              pulseUnit: try rational(measure.int64(7), measure.int64(8)), pickupLength: pickup))
            }
            try event.bind([.text(movementID.description)])
            while try event.step() {
                guard let kind = TimingEventKind(rawValue: event.text(1)) else { throw DocumentError.corrupt("Unknown timing event kind.") }
                track.events.append(TimingEvent(id: try id(event.text(0), EventID.self), kind: kind, measureID: try id(event.text(2), MeasureID.self),
                                                beatIndex: event.int(3), notatedDuration: try rational(event.int64(4), event.int64(5)),
                                                baselineSeconds: event.double(6)))
            }
            try anchor.bind([.text(movementID.description)])
            while try anchor.step() {
                track.anchors.append(AudioAnchor(id: try id(anchor.text(0), AnchorID.self),
                                                 cursor: TimelineCursor(eventID: try id(anchor.text(1), EventID.self), fraction: try rational(anchor.int64(2), anchor.int64(3))),
                                                 assetID: try id(anchor.text(4), MediaAssetID.self), sampleFrame: anchor.int64(5),
                                                 sampleRate: anchor.double(6), locked: anchor.int(7) != 0))
            }
            let audio = try movement.optionalText(2).map { try id($0, MediaAssetID.self) }
            movements.append(Movement(id: movementID, name: movement.text(1), timing: track, audioAssetID: audio))
        }

        var sets: [ArrivalSet] = []
        let set = try db.prepare("SELECT id, movement_id, label, event_id, fraction_num, fraction_den, is_subset, notes, rehearsal_mark, measure_marker FROM arrival_set ORDER BY ordinal")
        while try set.step() {
            sets.append(ArrivalSet(id: try id(set.text(0), SetID.self), movementID: try id(set.text(1), MovementID.self), label: set.text(2),
                                   cursor: TimelineCursor(eventID: try id(set.text(3), EventID.self), fraction: try rational(set.int64(4), set.int64(5))),
                                   isSubset: set.int(6) != 0, notes: set.text(7), rehearsalMark: set.text(8), measureMarker: set.text(9)))
        }
        var transitions: [Transition] = []
        let transition = try db.prepare("SELECT id, to_set_id, model FROM transition ORDER BY rowid")
        while try transition.step() {
            transitions.append(Transition(id: try id(transition.text(0), TransitionID.self), toSetID: try id(transition.text(1), SetID.self),
                                          model: TransitionModel(rawValue: transition.text(2)) ?? .straight))
        }
        var formations: [SetID: Formation] = Dictionary(uniqueKeysWithValues: sets.map { ($0.id, Formation()) })
        let placement = try db.prepare("SELECT set_id, performer_id, state, x, y, z, facing FROM placement")
        while try placement.step() {
            let setID = try id(placement.text(0), SetID.self)
            let performerID = try id(placement.text(1), PerformerID.self)
            let value: Placement
            switch placement.text(2) {
            case "placed":
                guard !placement.isNull(3), !placement.isNull(4) else { throw DocumentError.corrupt("A placed position has no coordinates.") }
                value = .placed(Position(x: placement.double(3), y: placement.double(4), z: placement.double(5), facing: placement.double(6)))
            case "inactive": value = .inactive
            default: value = .unresolved
            }
            formations[setID, default: Formation()][performerID] = value
        }
        var forms: [Form] = []
        let form = try db.prepare("SELECT id, set_id, kind, x0, y0, x1, y1, bulge FROM form ORDER BY ordinal")
        let member = try db.prepare("SELECT performer_id FROM form_member WHERE form_id = ? ORDER BY ordinal")
        while try form.step() {
            let start = Point2(form.double(3), form.double(4)), end = Point2(form.double(5), form.double(6))
            let geometry: FormGeometry = form.text(2) == "arc" ? .arc(start: start, end: end, bulge: form.double(7)) : .line(start: start, end: end)
            let formID = try id(form.text(0), FormID.self)
            try member.bind([.text(formID.description)])
            var members: [PerformerID] = []
            while try member.step() { members.append(try id(member.text(0), PerformerID.self)) }
            forms.append(Form(id: formID, setID: try id(form.text(1), SetID.self), geometry: geometry, members: members))
        }

        let show = Show(id: showID, title: title, field: field, sections: sections, performers: performers, movements: movements, sets: sets,
                        formations: formations, transitions: transitions, forms: forms, mediaAssets: assets, analysis: analysis, countingMode: countingMode)
        do { try show.validate() } catch { throw DocumentError.corrupt("The show data is inconsistent: \(error)") }
        return show
    }
}
