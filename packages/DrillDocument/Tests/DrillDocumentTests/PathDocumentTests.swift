import XCTest
import DrillTiming
import DrillCore
@testable import DrillDocument

final class PathDocumentTests: XCTestCase {
    /// The sample show with a delayed start, a curved leg and a mid-count corner in its first move.
    func makePathShow() throws -> DocumentSession {
        let session = try DocumentSession(show: try SampleShow.make())
        let show = session.show
        let set2 = show.sets[1].id
        let movers = show.performers.map(\.id).filter {
            guard let a = show.formation(show.sets[0].id)[$0].position, let b = show.formation(set2)[$0].position else { return false }
            return a.point.distance(to: b.point) > 1
        }
        XCTAssertGreaterThanOrEqual(movers.count, 3)
        let counts = try show.moveCounts(into: set2)
        try session.perform(try session.show.makeHoldPhases(into: set2, performers: [movers[0]], startHold: Rational(2), endHold: nil))
        try session.perform(try session.show.makeCurveLeg(into: set2, performer: movers[1], segment: 0, sagitta: 1.5))
        let corner = Rational(9, 2)
        let start = try XCTUnwrap(session.show.formation(show.sets[0].id)[movers[2]].position).point
        try session.perform(try session.show.makeInsertWaypoint(into: set2, performer: movers[2], atCount: corner, at: start + Point2(0, 3)))
        XCTAssertEqual(session.show.pathCount, 3)
        XCTAssertEqual(session.show.path(into: set2, performer: movers[2])?.totalCounts, counts)
        return session
    }

    func testPathsRoundTripByteForByteAndRequireTheCapability() throws {
        let session = try makePathShow()
        let document = ShowDocument(show: session.show)
        let data = try DocumentCodec.encode(document)
        let reopened = try DocumentCodec.decode(data)
        XCTAssertEqual(reopened.show, session.show)
        XCTAssertNil(reopened.readOnlyReason)
        XCTAssertEqual(try DocumentCodec.encode(reopened), data, "the same show encodes to the same bytes")

        let manifest = try JSONDecoder().decode(Manifest.self, from: try XCTUnwrap(try ZipArchive.read(data).first { $0.path == "manifest.json" }).data)
        XCTAssertTrue(manifest.capabilities.contains("drill.paths.v1"))
        XCTAssertTrue(manifest.requiredCapabilities.contains("drill.paths.v1"))
        XCTAssertTrue(FormatIdentity.knownCapabilities.contains("drill.paths.v1"))

        // A reader built without paths opens the file read-only instead of flattening the routes on save.
        var older = FormatIdentity.knownCapabilities
        older.remove("drill.paths.v1")
        let locked = try DocumentCodec.decode(data, knownCapabilities: older)
        XCTAssertTrue(locked.readOnlyReason?.contains("drill.paths.v1") == true, locked.readOnlyReason ?? "not read-only")

        // Without paths, the capability is not claimed and older readers edit as before.
        let plain = try DocumentCodec.encode(ShowDocument(show: try SampleShow.make()))
        XCTAssertNil(try DocumentCodec.decode(plain, knownCapabilities: older).readOnlyReason)
    }

    func testRowsAreWrittenInArrivalRosterAndSegmentOrder() throws {
        let session = try makePathShow()
        let db = try SQLiteDatabase(bytes: try ShowDatabase.encode(session.show, writer: "test"))
        XCTAssertEqual(db.userVersion, ShowDatabase.currentSchemaVersion)
        let rows = try db.prepare("SELECT performer_id, ordinal, kind FROM path_segment ORDER BY rowid")
        var order: [(String, Int64, String)] = []
        while try rows.step() { order.append((rows.text(0), rows.int64(1), rows.text(2))) }
        XCTAssertEqual(order.count, session.show.pathSegmentCount)
        let roster = Dictionary(uniqueKeysWithValues: session.show.performers.enumerated().map { ($1.id.description, $0) })
        let keys = order.map { (roster[$0.0]!, $0.1) }
        XCTAssertEqual(keys.map { "\($0.0)-\($0.1)" }, keys.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map { "\($0.0)-\($0.1)" })
        XCTAssertEqual(Set(order.map(\.2)), ["hold", "line", "arc"])
    }

    func testSchema4FilesMigrateWithNoPaths() throws {
        let base = try SampleShow.make()
        let db = try SQLiteDatabase(bytes: try ShowDatabase.encode(base, writer: "test"))
        try db.execute("DROP TABLE path_segment")
        try db.setUserVersion(4)
        try ShowDatabase.migrate(db)
        XCTAssertEqual(db.userVersion, ShowDatabase.currentSchemaVersion)
        let migrated = try ShowDatabase.read(db)
        XCTAssertEqual(migrated, base)
        XCTAssertEqual(migrated.pathCount, 0)
    }

    func testDamagedSegmentRowsAreRejected() throws {
        let session = try makePathShow()
        let bytes = try ShowDatabase.encode(session.show, writer: "test")
        let damage = [
            "UPDATE path_segment SET ordinal = ordinal + 10 WHERE ordinal = 0",                     // gap in ordinals
            "UPDATE path_segment SET counts_den = 0",                                               // zero denominator
            "UPDATE path_segment SET counts_num = 0 WHERE ordinal = 0",                             // no duration
            "UPDATE path_segment SET counts_num = 1.5 WHERE ordinal = 0",                           // not an integer
            "UPDATE path_segment SET x1 = 3 WHERE kind = 'hold'",                                   // a hold has no point
            "UPDATE path_segment SET sweep = 10 WHERE kind = 'line'",                               // a line has no sweep
            "UPDATE path_segment SET sweep = NULL WHERE kind = 'arc'",                              // an arc needs a sweep
            "UPDATE path_segment SET sweep = 400 WHERE kind = 'arc'",                               // sweep out of range
            "UPDATE path_segment SET x1 = x1 + 1 WHERE kind = 'line'",                              // does not end at the set
            "UPDATE path_segment SET counts_num = counts_num + counts_den WHERE ordinal = 0",       // wrong total
            "UPDATE path_segment SET transition_id = '\(TransitionID().description)'",              // missing move
        ]
        for sql in damage {
            let db = try SQLiteDatabase(bytes: bytes)
            try db.execute("PRAGMA foreign_keys = OFF")
            try db.execute(sql)
            XCTAssertThrowsError(try ShowDatabase.read(db), sql) { error in
                guard case .corrupt? = error as? DocumentError else { return XCTFail("\(sql): \(error)") }
            }
        }
        // An unknown kind (from a future writer that dropped the CHECK) is refused, never flattened.
        let db = try SQLiteDatabase(bytes: bytes)
        try db.execute("""
        CREATE TABLE p2 AS SELECT * FROM path_segment; DROP TABLE path_segment; ALTER TABLE p2 RENAME TO path_segment;
        UPDATE path_segment SET kind = 'cubic' WHERE kind = 'arc';
        """)
        XCTAssertThrowsError(try ShowDatabase.read(db)) { XCTAssertTrue("\($0)".contains("cubic")) }
    }

    func testPrePathsRecoveryJournalReplays() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fw-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let document = ShowDocument(show: try SampleShow.make())
        let journal = RecoveryJournal(directory: dir)
        try journal.begin(base: document)
        let session = try DocumentSession(show: document.show)
        session.observe { try? journal.append($0) }
        try session.perform(try session.show.makeCreateSet(after: session.show.sets.last!.id, counts: 8))
        // Rewrite the journal as a writer from before paths: no `paths` key on any move.
        let url = dir.appendingPathComponent("journal.jsonl")
        func strip(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                object["paths"] = nil
                return object.mapValues(strip)
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { line -> String in
            let old = strip(try JSONSerialization.jsonObject(with: Data(line.utf8)))
            return String(decoding: try JSONSerialization.data(withJSONObject: old), as: UTF8.self)
        }
        XCTAssertFalse(lines.joined().contains("\"paths\""))
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let recovery = try XCTUnwrap(try RecoveryJournal.recover(from: dir))
        let (restored, _) = try RecoveryJournal.restore(recovery)
        XCTAssertEqual(restored.show, session.show)
    }
}
