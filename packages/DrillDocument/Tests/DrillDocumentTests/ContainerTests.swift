import XCTest
import DrillTiming
import DrillCore
import DrillMedia
@testable import DrillDocument

final class ContainerTests: XCTestCase {
    func testHashVectors() {
        XCTAssertEqual(SHA256.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let long = Data(String(repeating: "a", count: 1000).utf8)
        XCTAssertEqual(SHA256.hex(long), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testZipRoundTripAndSafety() throws {
        let archive = try ZipArchive.write([("a.txt", Data("hello".utf8)), ("dir/b.bin", Data([0, 1, 2, 255]))])
        let members = try ZipArchive.read(archive)
        XCTAssertEqual(members.map(\.path), ["a.txt", "dir/b.bin"])
        XCTAssertEqual(members[1].data, Data([0, 1, 2, 255]))

        for bad in ["../evil", "/abs", "a/../../b", "C:/x", "a\\b", "a//b"] {
            XCTAssertThrowsError(try ZipArchive.validate(path: bad), bad)
        }
        // Flip one content byte: CRC check must fail.
        var damaged = archive
        let index = damaged.firstRange(of: Data("hello".utf8))!.lowerBound
        damaged[index] = UInt8(ascii: "j")
        XCTAssertThrowsError(try ZipArchive.read(damaged)) { XCTAssertTrue("\($0)".contains("checksum")) }
        // A compressed member (method 8) is refused rather than misread.
        var compressed = archive
        compressed[compressed.startIndex + 8] = 8
        let central = compressed.firstRange(of: Data([0x50, 0x4b, 0x01, 0x02]))!.lowerBound
        compressed[central + 10] = 8
        XCTAssertThrowsError(try ZipArchive.read(compressed)) { XCTAssertTrue("\($0)".contains("compression")) }
        XCTAssertThrowsError(try ZipArchive.read(Data("not a zip".utf8)))
    }

    func makeDocument() throws -> ShowDocument {
        var document = ShowDocument(show: try SampleShow.make())
        let wav = Self.clickTrack(seconds: 4, sampleRate: 8000)
        let info = document.embed(wav, fileExtension: "wav", originalFilename: "click.wav", sampleRate: 8000, frameCount: 32_000, channelCount: 1)
        let session = try DocumentSession(show: document.show)
        let movement = session.show.movements[0].id
        try session.perform(try session.show.makeImportAudio(info, movementID: movement))
        let map = try session.show.timingMap(for: movement)
        try session.perform(try session.show.makeAlignHere(movementID: movement, cursor: try map.cursor(measureNumber: 1, beat: 1), sampleFrame: 4000).command)
        document.show = session.show
        return document
    }

    static func clickTrack(seconds: Double, sampleRate: Int, bpm: Double = 120) -> Data {
        let frames = Int(seconds * Double(sampleRate))
        var samples = [Float](repeating: 0, count: frames)
        let beat = Int(60 / bpm * Double(sampleRate))
        var i = 0
        while i < frames {
            for k in 0..<min(200, frames - i) { samples[i + k] = Float(sin(Double(k) * 0.9)) * 0.8 * Float(1 - Double(k) / 200) }
            i += beat
        }
        return WAVDecoder.encode16(samples, sampleRate: sampleRate)
    }

    func testDocumentRoundTripPreservesEverything() throws {
        let document = try makeDocument()
        let data = try DocumentCodec.encode(document)
        let reopened = try DocumentCodec.decode(data)
        XCTAssertEqual(reopened.show, document.show)
        XCTAssertEqual(reopened.assets, document.assets)
        XCTAssertNil(reopened.readOnlyReason)
        // Deterministic bytes for the same content.
        XCTAssertEqual(try DocumentCodec.encode(reopened), data)
        let members = try ZipArchive.read(data).map(\.path)
        XCTAssertEqual(members.first, "manifest.json")
        XCTAssertTrue(members.contains("show.sqlite"))
        XCTAssertTrue(members.contains(document.show.mediaAssets[0].archivePath))
    }

    func testNewerMajorVersionIsRefusedWithoutChanges() throws {
        let data = try DocumentCodec.encode(try makeDocument())
        var members = try ZipArchive.read(data)
        var manifest = try JSONDecoder().decode(Manifest.self, from: members[0].data)
        manifest.formatVersion = FormatVersion(major: 2, minor: 0)
        members[0].data = try JSONEncoder().encode(manifest)
        let newer = try ZipArchive.write(members)
        XCTAssertThrowsError(try DocumentCodec.decode(newer)) { error in
            XCTAssertEqual(error as? DocumentError, .newerFormat(major: 2, minor: 0))
            XCTAssertTrue("\(error)".contains("not changed"))
        }
    }

    func testUnknownExtensionsArePreservedAndRequiredOnesBlockEditing() throws {
        var document = try makeDocument()
        document.extensionMembers["extensions/com.example.notes/data.json"] = Data("{\"x\":1}".utf8)
        document.extensions = [ManifestExtension(namespace: "com.example.notes", required: false)]
        let reopened = try DocumentCodec.decode(try DocumentCodec.encode(document))
        XCTAssertEqual(reopened.extensionMembers, document.extensionMembers)
        XCTAssertNil(reopened.readOnlyReason)

        document.extensions = [ManifestExtension(namespace: "com.example.future", required: true)]
        let locked = try DocumentCodec.decode(try DocumentCodec.encode(document))
        XCTAssertNotNil(locked.readOnlyReason)
    }

    func testTamperedMemberIsReportedAsDamage() throws {
        let data = try DocumentCodec.encode(try makeDocument())
        var members = try ZipArchive.read(data)
        let i = members.firstIndex { $0.path == "show.sqlite" }!
        members[i].data[members[i].data.startIndex + 2000] ^= 0xFF
        XCTAssertThrowsError(try DocumentCodec.decode(try ZipArchive.write(members))) { error in
            guard case .corrupt? = error as? DocumentError else { return XCTFail("\(error)") }
        }
    }

    func testMigrationRunsOnACopy() throws {
        let original = try ShowDatabase.encode(try SampleShow.make(), writer: "test")
        let db = try SQLiteDatabase(bytes: original)
        try db.setUserVersion(0)
        try ShowDatabase.migrate(db, to: 1, using: [0: { db in
            try db.execute("ALTER TABLE performer ADD COLUMN legacy_flag INTEGER")
        }])
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM pragma_table_info('performer') WHERE name = 'legacy_flag'"), 1)
        XCTAssertEqual(db.userVersion, 1)
        XCTAssertEqual(try ShowDatabase.decode(original).title, "Sample: First Light", "original bytes untouched")
        // A newer schema than we know is refused.
        let newer = try SQLiteDatabase(bytes: original)
        try newer.setUserVersion(9)
        XCTAssertThrowsError(try ShowDatabase.migrate(newer)) { XCTAssertEqual($0 as? DocumentError, .newerSchema(9)) }
    }

    func testCountingModeAndSetMarkersRoundTripAndMigrateFromSchema1() throws {
        var show = try SampleShow.make()
        show.countingMode = .counts
        show.sets[1].rehearsalMark = "CC"
        show.sets[1].measureMarker = "222-223"
        let reopened = try ShowDatabase.decode(try ShowDatabase.encode(show, writer: "test"))
        XCTAssertEqual(reopened, show)

        // Rebuild a schema 1 database by removing the schema 2 columns, then open it.
        let base = try SampleShow.make()
        let db = try SQLiteDatabase(bytes: try ShowDatabase.encode(base, writer: "test"))
        try db.execute("""
        ALTER TABLE show DROP COLUMN counting_mode;
        ALTER TABLE arrival_set DROP COLUMN rehearsal_mark;
        ALTER TABLE arrival_set DROP COLUMN measure_marker;
        """)
        try db.execute("ALTER TABLE performer DROP COLUMN symbol; DROP TABLE field_note;")
        try db.setUserVersion(1)
        try ShowDatabase.migrate(db)
        XCTAssertEqual(db.userVersion, ShowDatabase.currentSchemaVersion)
        let migrated = try ShowDatabase.read(db)
        XCTAssertEqual(migrated.countingMode, .measures)
        XCTAssertTrue(migrated.sets.allSatisfy { $0.rehearsalMark.isEmpty && $0.measureMarker.isEmpty })
        XCTAssertEqual(migrated, base)
    }

    func testPerformerSymbolsRoundTripAndMigrateFromSchema2() throws {
        var show = try SampleShow.make()
        show.sections[0].symbol = .diamond
        show.performers[0].symbol = .slash
        let reopened = try ShowDatabase.decode(try ShowDatabase.encode(show, writer: "test"))
        XCTAssertEqual(reopened, show)
        XCTAssertEqual(reopened.symbol(for: reopened.performers[0]), .slash)
        XCTAssertEqual(reopened.symbol(for: reopened.performers[1]), .diamond)

        // A schema 2 database has no performer symbols; everyone follows their section.
        let base = try SampleShow.make()
        let db = try SQLiteDatabase(bytes: try ShowDatabase.encode(base, writer: "test"))
        try db.execute("ALTER TABLE performer DROP COLUMN symbol; DROP TABLE field_note;")
        try db.setUserVersion(2)
        try ShowDatabase.migrate(db)
        XCTAssertEqual(db.userVersion, ShowDatabase.currentSchemaVersion)
        let migrated = try ShowDatabase.read(db)
        XCTAssertTrue(migrated.performers.allSatisfy { $0.symbol == nil })
        XCTAssertEqual(migrated, base)
    }

    func testFieldNotesRoundTripAndMigrateFromSchema3() throws {
        var show = try SampleShow.make()
        show.fieldNotes = [FieldNote(setID: show.sets[1].id, position: Point2(-20.5, 8.25), text: "Flags arrive to pick up new\nflags behind backdrop."),
                           FieldNote(setID: show.sets[0].id, position: Point2(3, -4))]
        let reopened = try ShowDatabase.decode(try ShowDatabase.encode(show, writer: "test"))
        XCTAssertEqual(reopened, show)

        let base = try SampleShow.make()
        let db = try SQLiteDatabase(bytes: try ShowDatabase.encode(base, writer: "test"))
        try db.execute("DROP TABLE field_note")
        try db.setUserVersion(3)
        try ShowDatabase.migrate(db)
        XCTAssertEqual(db.userVersion, 4)
        XCTAssertEqual(try ShowDatabase.read(db), base)
    }

    func testFileSaveKeepsPreviousVersionAndFailedSaveChangesNothing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fw-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Show.fieldwork")
        var document = try makeDocument()
        try DocumentFile.save(document, to: url)
        let first = try Data(contentsOf: url)
        document.show.title = "Second"
        try DocumentFile.save(document, to: url)
        XCTAssertEqual(try DocumentFile.open(url).show.title, "Second")
        XCTAssertEqual(try Data(contentsOf: DocumentFile.backupURL(for: url)), first)

        // An invalid document must not replace the good file.
        var broken = document
        broken.assets = [:]
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try DocumentFile.save(broken, to: url))
        XCTAssertEqual(try Data(contentsOf: url), before)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testRecoveryReplaysCompleteJournalLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fw-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let document = try makeDocument()
        let journal = RecoveryJournal(directory: dir)
        try journal.begin(base: document)
        let session = try DocumentSession(show: document.show)
        session.observe { try? journal.append($0) }
        let preset = session.show.sets[0].id
        try session.perform(try session.show.makeTranslate(session.show.performers.map(\.id), at: preset, by: Point2(1, 1)))
        try session.perform(.renameShow("Recovered Show"))
        session.undo()
        try session.perform(try session.show.makeCreateSet(after: session.show.sets.last!.id, counts: 8))
        // Simulate a crash in the middle of writing the next entry.
        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent("journal.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"v\":1,\"event\":{\"revis".utf8))
        try handle.close()

        let recovery = try XCTUnwrap(try RecoveryJournal.recover(from: dir))
        XCTAssertTrue(recovery.ignoredPartialLine)
        XCTAssertEqual(recovery.events.count, 4)
        let (restored, restoredDocument) = try RecoveryJournal.restore(recovery)
        XCTAssertEqual(restored.show, session.show)
        XCTAssertTrue(restored.isDirty, "recovered state is clearly unsaved")
        XCTAssertEqual(restoredDocument.assets.count, 1)
    }

    func testPlatformHashesMatchThePortableImplementation() {
        // On Apple platforms SHA256/CRC32 use CryptoKit and zlib; both must agree with the portable code.
        for count in [0, 1, 55, 56, 63, 64, 65, 1000, 70_001] {
            let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) })
            XCTAssertEqual(SHA256.digest(data), SHA256.portableDigest(data), "SHA-256 of \(count) bytes")
            XCTAssertEqual(CRC32.checksum(data), CRC32.portableChecksum(data), "CRC-32 of \(count) bytes")
        }
    }

    func testJournalStartedFromEncodedBytesRecovers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fw-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let document = try makeDocument()
        let journal = RecoveryJournal(directory: dir)
        try journal.begin(encodedBase: try DocumentCodec.encode(document))
        let session = try DocumentSession(show: document.show)
        session.observe { try? journal.append($0) }
        try session.perform(.renameShow("From Bytes"))
        let recovery = try XCTUnwrap(try RecoveryJournal.recover(from: dir))
        let (restored, restoredDocument) = try RecoveryJournal.restore(recovery)
        XCTAssertEqual(restored.show, session.show)
        XCTAssertEqual(restoredDocument.assets, document.assets)
    }

    func testCorruptDatabaseBytesAreRejected() {
        XCTAssertThrowsError(try ShowDatabase.decode(Data(repeating: 7, count: 4096)))
    }
}
