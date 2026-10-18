import Foundation
import DrillCore

/// Crash recovery for one open document. The directory holds a base snapshot
/// (`base.fieldwork`, written at open/save), the assets imported since, and
/// an append-only journal of committed commands. Recovery replays only
/// complete, versioned lines after the snapshot.
public final class RecoveryJournal {
    public static let journalVersion = 1

    struct Line: Codable {
        var v: Int
        var event: CommitEvent
    }

    public let directory: URL
    private var handle: FileHandle?

    public init(directory: URL) {
        self.directory = directory
    }

    deinit { try? handle?.close() }

    var baseURL: URL { directory.appendingPathComponent("base.fieldwork") }
    var journalURL: URL { directory.appendingPathComponent("journal.jsonl") }
    var assetsURL: URL { directory.appendingPathComponent("assets", isDirectory: true) }

    /// Starts a fresh journal from a snapshot (on open, new document and after each save).
    public func begin(base: ShowDocument) throws {
        try? handle?.close()
        handle = nil
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: assetsURL)
        try DocumentFile.save(base, to: baseURL)
        try? FileManager.default.removeItem(at: DocumentFile.backupURL(for: baseURL))
        FileManager.default.createFile(atPath: journalURL.path, contents: Data())
        handle = try FileHandle(forWritingTo: journalURL)
    }

    /// Persists bytes of an asset imported after the snapshot so recovery can rebuild it.
    public func recordAsset(path: String, data: Data) throws {
        try ZipArchive.validate(path: path)
        let name = (path as NSString).lastPathComponent
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try data.write(to: assetsURL.appendingPathComponent(name), options: .atomic)
    }

    /// Appends one committed event and flushes it to disk.
    public func append(_ event: CommitEvent) throws {
        guard let handle else { throw DocumentError.io("The recovery journal is not open.") }
        var line = try JSONEncoder().encode(Line(v: RecoveryJournal.journalVersion, event: event))
        line.append(0x0A)
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    /// Removes the journal (clean close).
    public func discard() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: directory)
    }

    public struct Recovery {
        public var base: ShowDocument
        public var events: [CommitEvent]
        /// A trailing incomplete line (crash mid-write) was ignored.
        public var ignoredPartialLine: Bool
    }

    /// Reads a journal left behind by a previous session, if any.
    public static func recover(from directory: URL) throws -> Recovery? {
        let journal = RecoveryJournal(directory: directory)
        guard FileManager.default.fileExists(atPath: journal.baseURL.path) else { return nil }
        var base = try DocumentFile.open(journal.baseURL)
        if let files = try? FileManager.default.contentsOfDirectory(at: journal.assetsURL, includingPropertiesForKeys: nil) {
            for file in files { base.assets["assets/" + file.lastPathComponent] = try Data(contentsOf: file) }
        }
        let data = (try? Data(contentsOf: journal.journalURL)) ?? Data()
        var events: [CommitEvent] = []
        var partial = false
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        for (i, raw) in lines.enumerated() {
            if raw.isEmpty { continue }
            let isLast = i == lines.count - 1
            guard let line = try? JSONDecoder().decode(Line.self, from: Data(raw)) else {
                // Only the final line may be torn by a crash; anything else is damage.
                if isLast { partial = true; break }
                throw DocumentError.corrupt("The recovery journal is damaged at entry \(i + 1).")
            }
            guard line.v <= journalVersion else { throw DocumentError.corrupt("The recovery journal was written by a newer version.") }
            events.append(line.event)
        }
        return Recovery(base: base, events: events, ignoredPartialLine: partial)
    }

    /// Rebuilds a session from a recovery: base snapshot + replayed commands, marked unsaved.
    public static func restore(_ recovery: Recovery) throws -> (DocumentSession, ShowDocument) {
        let session = try DocumentSession(show: recovery.base.show)
        for event in recovery.events { try session.replay(event) }
        session.markUnsaved()
        var document = recovery.base
        document.show = session.show
        return (session, document)
    }
}
