import AppKit
import DrillTiming
import DrillCore
import DrillDocument

/// NSDocument integration. NSDocument is the only writer of `.fieldwork`
/// files on macOS: it coordinates file access and performs the safe
/// (temporary file + atomic replace) save using bytes from `DocumentCodec`.
/// A separate recovery journal (not the document file) records every
/// committed command so a crash loses nothing.
///
/// The Objective-C name is fixed so Info.plist's `NSDocumentClass` can name it
/// as plain `FieldworkDocument`; the two must match or macOS refuses to open
/// `.fieldwork` files and Save As loses its file type.
@objc(FieldworkDocument)
final class FieldworkDocument: NSDocument {
    private(set) var model: EditorModel?
    /// The decoded container, kept so unknown optional extensions survive a rewrite.
    private var container: ShowDocument?
    private var journal: RecoveryJournal?
    let recoveryID = UUID()
    private var lastSaved: Date?
    private(set) var isRecovered = false

    /// For documents created by the New Show flow, the sample or recovery.
    var pendingShow: Show?
    var pendingAssets: [String: Data] = [:]
    var startTourOnOpen = false
    var recoveredMessage: String?
    var audioToImport: URL?

    override init() {
        super.init()
        hasUndoManager = false
    }

    override class var autosavesInPlace: Bool { false }

    static var typeIdentifier: String { NSDocumentController.shared.defaultType ?? FormatIdentity.uniformTypeIdentifier }

    // MARK: Model setup

    @MainActor
    private func configure(show: Show, assets: [String: Data], readOnlyReason: String?, encoded: Data? = nil) throws {
        let session = try DocumentSession(show: show)
        let model = EditorModel(session: session, assets: assets, readOnlyReason: readOnlyReason)
        model.document = self
        self.model = model
        startJournal(encoded: encoded)
    }

    override func makeWindowControllers() {
        MainActor.assumeIsolated { makeEditorWindow() }
    }

    @MainActor
    private func makeEditorWindow() {
        if model == nil {
            do {
                let show = try pendingShow ?? Show.makeNew(title: "Untitled Show")
                try configure(show: show, assets: pendingAssets, readOnlyReason: nil)
                if let recoveredMessage {
                    isRecovered = true
                    model?.session.markUnsaved()
                    model?.recoveredBanner = recoveredMessage
                    updateChangeCount(.changeDone)
                }
            } catch {
                presentError(error)
                return
            }
        }
        guard let model else { return }
        if startTourOnOpen { model.restartTour() }
        addWindowController(EditorWindowController(document: self, model: model))
        if let url = audioToImport {
            audioToImport = nil
            model.importAudio(from: url)
        }
    }

    // MARK: Reading and writing

    override func read(from data: Data, ofType typeName: String) throws {
        do {
            let decoded = try DocumentCodec.decode(data)
            container = decoded
            try MainActor.assumeIsolated {
                try configure(show: decoded.show, assets: decoded.assets, readOnlyReason: decoded.readOnlyReason, encoded: data)
            }
        } catch {
            throw NSError(domain: "org.fieldwork", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "“\(fileURL?.lastPathComponent ?? "This file")” could not be opened.",
                NSLocalizedRecoverySuggestionErrorKey: "\(error)",
            ])
        }
    }

    /// Everything a save needs, captured on the main thread. Encoding then runs
    /// on NSDocument's background writer so the window never freezes.
    private struct SaveSnapshot {
        var document: ShowDocument
        var state: UUID
        var readOnlyReason: String?
    }

    private var saveSnapshot: SaveSnapshot?
    /// Bytes from the most recent successful encode, reused to restart the journal.
    private var lastEncoded: (state: UUID, data: Data)?

    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool { true }

    @MainActor
    private func makeSaveSnapshot() -> SaveSnapshot? {
        guard let model else { return nil }
        var document = container ?? ShowDocument(show: model.show)
        document.show = model.show
        document.assets = model.assets
        return SaveSnapshot(document: document, state: model.session.currentStateID, readOnlyReason: model.readOnlyReason)
    }

    /// Runs on a background thread for saves (see `canAsynchronouslyWrite`).
    override func data(ofType typeName: String) throws -> Data {
        let snapshot = saveSnapshot ?? (Thread.isMainThread ? MainActor.assumeIsolated { makeSaveSnapshot() } : nil)
        // The snapshot is taken, so editing can continue while the bytes are produced.
        unblockUserInteraction()
        guard let snapshot else { throw NSError(domain: "org.fieldwork", code: 2, userInfo: [NSLocalizedDescriptionKey: "Nothing to save."]) }
        if let reason = snapshot.readOnlyReason {
            throw NSError(domain: "org.fieldwork", code: 3, userInfo: [NSLocalizedDescriptionKey: "This show is read-only.", NSLocalizedRecoverySuggestionErrorKey: reason])
        }
        do {
            let data = try DocumentCodec.encode(snapshot.document)
            // Never hand NSDocument bytes we cannot read back.
            _ = try DocumentCodec.decode(data)
            lastEncoded = (snapshot.state, data)
            return data
        } catch {
            throw NSError(domain: "org.fieldwork", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "The show could not be saved. Your previous file was not changed.",
                NSLocalizedRecoverySuggestionErrorKey: "\(error)",
            ])
        }
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        let snapshot = MainActor.assumeIsolated { makeSaveSnapshot() }
        saveSnapshot = snapshot
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            Self.onMain {
                self?.saveSnapshot = nil
                if error == nil, saveOperation != .autosaveElsewhereOperation, let snapshot {
                    MainActor.assumeIsolated { self?.didSave(snapshot) }
                }
                completionHandler(error)
            }
        }
    }

    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    @MainActor
    private func didSave(_ snapshot: SaveSnapshot) {
        guard let model else { return }
        model.session.markSaved(state: snapshot.state)
        isRecovered = false
        model.recoveredBanner = nil
        lastSaved = Date()
        container = ShowDocument(show: snapshot.document.show, assets: snapshot.document.assets,
                                 extensionMembers: container?.extensionMembers ?? [:], extensions: container?.extensions ?? [])
        // If nothing changed during the save, the journal restarts from the bytes just written.
        let unchanged = model.session.currentStateID == snapshot.state
        startJournal(encoded: unchanged && lastEncoded?.state == snapshot.state ? lastEncoded?.data : nil)
        lastEncoded = nil
        if model.session.isDirty { updateChangeCount(.changeDone) }
        model.statusMessage = "Saved \(fileURL?.lastPathComponent ?? "")"
    }

    // MARK: Change tracking and recovery

    @MainActor
    func didCommit(_ event: CommitEvent) {
        do { try journal?.append(event) } catch {
            model?.statusMessage = "Recovery journal unavailable: \(error.localizedDescription)"
        }
        updateChangeCount((model?.session.isDirty ?? false) ? .changeDone : .changeCleared)
    }

    @MainActor
    func recordAsset(path: String, data: Data) {
        try? journal?.recordAsset(path: path, data: data)
    }

    @MainActor
    func currentDocumentSnapshot() -> ShowDocument? {
        guard let model else { return nil }
        return ShowDocument(show: model.show, assets: model.assets)
    }

    /// Restarts crash recovery. `encoded` is the show's current bytes when
    /// already known (just opened or saved), which avoids encoding again.
    @MainActor
    private func startJournal(encoded: Data? = nil) {
        guard let model else { return }
        let dir = RecoveryStore.directory(for: recoveryID)
        let journal = RecoveryJournal(directory: dir)
        do {
            if let encoded {
                try journal.begin(encodedBase: encoded)
            } else {
                try journal.begin(base: ShowDocument(show: model.show, assets: model.assets))
            }
            RecoveryStore.writeOrigin(fileURL: fileURL, title: model.show.title, in: dir)
            self.journal = journal
        } catch {
            self.journal = nil
            model.statusMessage = "Crash recovery is unavailable: \(error.localizedDescription)"
        }
    }

    override func close() {
        journal?.discard()
        journal = nil
        MainActor.assumeIsolated { model?.transport.stop() }
        super.close()
    }

    @MainActor
    var saveStateText: String {
        if model?.readOnlyReason != nil { return "Read-only" }
        if isRecovered { return "Recovered · not saved" }
        if model?.session.isDirty == true { return "Edited" }
        if let lastSaved { return "Saved \(lastSaved.formatted(date: .omitted, time: .shortened))" }
        return fileURL == nil ? "Not saved" : "Saved"
    }
}

/// Location and metadata of per-document recovery journals.
enum RecoveryStore {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Fieldwork/Recovery", isDirectory: true)
    }

    static func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    static func writeOrigin(fileURL: URL?, title: String, in dir: URL) {
        let info: [String: String] = ["title": title, "file": fileURL?.path ?? "", "written": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: info) { try? data.write(to: dir.appendingPathComponent("origin.json"), options: .atomic) }
    }

    static func origin(in dir: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("origin.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return object
    }

    /// Journals left by sessions that did not close cleanly, excluding open documents.
    static func leftovers(excluding open: Set<UUID>) -> [URL] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { url in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return false }
            return !open.contains(id)
        }
    }
}
