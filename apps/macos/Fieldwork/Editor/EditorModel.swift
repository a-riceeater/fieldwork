import AppKit
import Combine
import QuartzCore
import DrillTiming
import DrillCore
import DrillDocument
import DrillMedia
import DrillExport
import FieldworkTour

enum EditorTool: String, CaseIterable, Identifiable {
    case select, line, arc, text
    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: return "Select"
        case .line: return "Line"
        case .arc: return "Arc"
        case .text: return "Text"
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .line: return "line.diagonal"
        case .arc: return "circle.bottomhalf.filled"
        case .text: return "textformat"
        }
    }
}

/// The shapes Draw Next Set can draw on the field.
enum DrawTool: String, CaseIterable, Identifiable {
    case line, arc, block, circle, text
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .line: return "line.diagonal"
        case .arc: return "rainbow"
        case .block: return "square.grid.3x3"
        case .circle: return "circle.dashed"
        case .text: return "textformat"
        }
    }
}

/// A set being drawn as shapes before anyone stands in it. View state only:
/// nothing is saved until Auto Route commits one undoable change.
struct SetDraft: Equatable {
    var setID: SetID
    var shapes: [DrawnShape] = []
    var tool: DrawTool = .line
    /// Sections whose performers fill the shapes; everyone else holds their previous spot.
    var sections: Set<SectionID>
    var showsPreviousSet = true
    /// Set once Auto Route has placed performers, so the canvas shows them.
    var routed = false
}

enum AxisLock: String, CaseIterable, Identifiable {
    case none, horizontal, vertical
    var id: String { rawValue }
}

struct EditorAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// A timing edit waiting for the user to choose a resolution.
struct PendingConflict: Identifiable {
    let id = UUID()
    let conflict: TimingEditConflict
    /// Human labels for anchors ("m17 b1 @ 00:44.600").
    let anchorLabels: [AnchorID: String]
    let resolve: (TimingResolution) -> Void
}

/// View state for one open document. The `DocumentSession` owns the show;
/// this model owns selection, tools, playhead and tour progress (none of which
/// are saved in the show). Document commands run on the main actor in this
/// first milestone; they are short, validated and atomic.
@MainActor
final class EditorModel: ObservableObject {
    let session: DocumentSession
    weak var document: FieldworkDocument?
    var assets: [String: Data]

    @Published private(set) var revision = 0
    @Published var selection: Set<PerformerID> = [] {
        didSet {
            if selection != oldValue { cancelArrangement() }
            if !selection.isEmpty { focusedNoteID = nil }
        }
    }
    /// The field note shown in the inspector. Notes are focused, never selected with performers.
    @Published var focusedNoteID: NoteID?
    /// Text being typed into the focused note, drawn on the field before it commits.
    @Published var noteDraft: FieldNote?
    @Published var currentSetID: SetID {
        didSet {
            guard currentSetID != oldValue else { return }
            cancelArrangement()
            // A draft belongs to its set; going elsewhere ends it.
            if let draft, draft.setID != currentSetID { self.draft = nil }
        }
    }
    /// Draw Next Set in progress, if any.
    @Published var draft: SetDraft? {
        didSet { if draft?.shapes != oldValue?.shapes { cancelArrangement() } }
    }
    /// Text the Text tool and the Spell button put performers in.
    @Published var shapeText = ""
    /// The set Align Set Here pins: the last set the user chose. Scrubbing changes the
    /// set shown on the field, but not this, so a set can be aligned anywhere in the music.
    @Published private(set) var alignSetID: SetID
    @Published var tool: EditorTool = .select
    @Published var snapEnabled = true
    @Published var snapSteps: Double = 1
    /// Interval between neighbors for quick shapes and Place All, in steps.
    @Published var shapeSpacingSteps: Double = 2
    @Published var axisLock: AxisLock = .none
    /// Frame updates have their own publisher so the document UI stays idle while playing.
    let playbackPosition = PlaybackPosition()
    var playheadSeconds: Double {
        get { playbackPosition.seconds }
        set {
            if !isPlaying { objectWillChange.send() }
            playbackPosition.update(newValue, continuously: isPlaying)
        }
    }
    /// True while the canvas shows an interpolated frame between sets.
    @Published var isBetweenSets = false
    @Published private(set) var isPlaying = false
    @Published var playbackRate: Double = 1 { didSet { transport.rate = playbackRate } }
    @Published var wholeCountsOnly: Bool {
        didSet { preferences.set(wholeCountsOnly, forKey: "FieldworkWholeCountsOnly") }
    }
    /// Draws every performer as a circle in their section color, ignoring
    /// section and individual symbols. A per-user view preference, not show data.
    @Published var circlesOnly: Bool {
        didSet { preferences.set(circlesOnly, forKey: "FieldworkCirclesOnly") }
    }
    /// Fixed-size performer labels at every zoom level; a per-user view preference.
    @Published var alwaysShowLabels: Bool {
        didSet { preferences.set(alwaysShowLabels, forKey: "FieldworkAlwaysShowLabels") }
    }
    @Published var labelPlacement: PerformerLabelPlacement {
        didSet { preferences.set(labelPlacement.rawValue, forKey: "FieldworkLabelPlacement") }
    }
    /// Draws the field dark, as mowed grass or as graph paper. A per-user view preference, not show data.
    @Published var fieldStyle: FieldStyle {
        didSet { preferences.set(fieldStyle.rawValue, forKey: "FieldworkFieldStyle") }
    }
    /// Draws every performer's path into the current set, not only the selection's. A per-user view preference.
    @Published var showsAllPaths: Bool {
        didSet { preferences.set(showsAllPaths, forKey: "FieldworkShowAllPaths") }
    }
    @Published private(set) var isArranging = false
    private var arrangementTask: Task<DrillCommand, Error>?
    private var arrangementGeneration = UUID()
    @Published var statusMessage: String?
    @Published var alert: EditorAlert?
    @Published var conflict: PendingConflict?
    @Published var tour: Tour
    @Published var showExport = false
    @Published var showAddSection = false
    @Published var showProjectSettings = false
    @Published private(set) var peaks: WaveformPeaks?
    @Published private(set) var audioStatus = "No audio"
    @Published var readOnlyReason: String?
    @Published var recoveredBanner: String?

    /// One-shot view request for the canvas (fit/zoom), identified by a token.
    @Published private(set) var canvasRequest: (command: CanvasViewCommand, token: UUID)?
    func requestCanvas(_ command: CanvasViewCommand) { canvasRequest = (command, UUID()) }

    let transport = PlaybackTransport()
    private let preferences: UserDefaults
    private var displayTimer: Timer?
    private var displayLink: CADisplayLink?
    private weak var playbackView: NSView?
    private var displayTarget: PlaybackDisplayTarget?
    private var lastPlaybackSetIndex: Int?
    private var evaluatorCache: (revision: Int, evaluator: SceneEvaluator)?
    private var audioLoadGeneration = UUID()
    private var analysisCache: (revision: Int, issues: [DrillIssue])?
    private var draftPreviewCache: (revision: Int, shapes: [DrawnShape], members: [PerformerID], result: Result<[Point2], DrillError>)?

    init(session: DocumentSession, assets: [String: Data], readOnlyReason: String? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        wholeCountsOnly = preferences.bool(forKey: "FieldworkWholeCountsOnly")
        alwaysShowLabels = preferences.bool(forKey: "FieldworkAlwaysShowLabels")
        labelPlacement = PerformerLabelPlacement(rawValue: preferences.string(forKey: "FieldworkLabelPlacement") ?? "") ?? .front
        circlesOnly = preferences.bool(forKey: "FieldworkCirclesOnly")
        fieldStyle = preferences.string(forKey: "FieldworkFieldStyle").flatMap(FieldStyle.init(rawValue:)) ?? .dark
        showsAllPaths = preferences.bool(forKey: "FieldworkShowAllPaths")
        self.session = session
        self.assets = assets
        self.readOnlyReason = readOnlyReason
        currentSetID = session.show.sets[0].id
        alignSetID = session.show.sets[0].id
        tour = TourStore.load()
        revision = session.revision
        loadAudioForCurrentMovement()
    }

    deinit {
        displayTimer?.invalidate()
        displayLink?.invalidate()
        arrangementTask?.cancel()
    }

    // MARK: Model access

    var show: Show { session.show }
    var movementID: MovementID { show.movements[0].id }
    var movement: Movement { show.movements[0] }
    var map: TimingMap? { try? session.timingMap(for: movementID) }
    var hasAudio: Bool { movement.audioAssetID != nil }
    var isEditable: Bool { readOnlyReason == nil && !isPlaying && !isBetweenSets && !isArranging }
    var currentSet: ArrivalSet? { show.set(currentSetID) }
    var alignSet: ArrivalSet? { show.set(alignSetID) }
    var setsInMovement: [ArrivalSet] { show.sets(in: movementID) }

    var evaluator: SceneEvaluator? {
        if let cached = evaluatorCache, cached.revision == session.revision { return cached.evaluator }
        guard let e = try? SceneEvaluator(show: show, movementID: movementID, map: map) else { return nil }
        evaluatorCache = (session.revision, e)
        return e
    }

    var audioAsset: MediaAssetInfo? {
        guard let id = movement.audioAssetID else { return nil }
        return show.mediaAssets.first { $0.id == id }
    }

    /// Timeline length in seconds: the audio file, or the music when counts-only.
    var timelineDuration: Double {
        let music = (try? map?.audioTime(at: map!.endCursor)) ?? 60
        return max(audioAsset?.durationSeconds ?? 0, music, 1)
    }

    var currentPulse: Double { map?.locate(audioTime: playheadSeconds).pulse ?? 0 }

    // MARK: Commands

    @discardableResult
    func perform(_ command: DrillCommand) -> Bool {
        guard readOnlyReason == nil else {
            statusMessage = "This show is read-only."
            return false
        }
        do {
            let event = try session.perform(command)
            afterCommit(event)
            return true
        } catch {
            report(error)
            return false
        }
    }

    func perform(_ build: () throws -> DrillCommand) {
        do { perform(try build()) } catch { report(error) }
    }

    func undo() {
        guard let event = session.undo() else { return }
        afterCommit(event)
        statusMessage = "Undid \(event.name)"
    }

    func redo() {
        guard let event = session.redo() else { return }
        afterCommit(event)
        statusMessage = "Redid \(event.name)"
    }

    private func afterCommit(_ event: CommitEvent) {
        cancelArrangement()
        revision = session.revision
        document?.didCommit(event)
        if event.action == .perform {
            tour.handle(event.command.allKinds)
            TourStore.save(tour)
        }
        if show.set(currentSetID) == nil { currentSetID = setsInMovement.last?.id ?? show.sets[0].id }
        if show.set(alignSetID) == nil { alignSetID = currentSetID }
        selection = selection.filter { show.performer($0) != nil }
        if let id = focusedNoteID, show.fieldNote(id) == nil { focusedNoteID = nil }
        if let draft {
            if show.set(draft.setID) == nil { self.draft = nil } else { self.draft?.sections = draft.sections.filter { show.section($0) != nil } }
        }
        if case .batch(_, let list) = event.command, list.contains(where: { if case .setMovementAudio = $0 { return true }; return false }) {
            loadAudioForCurrentMovement()
        }
    }

    func report(_ error: Error) {
        let text: String
        if let e = error as? DrillError { text = e.message } else if let e = error as? TimingError { text = e.message } else { text = "\(error)" }
        statusMessage = text
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Runs a timing edit; contradictions become a choice sheet instead of a change.
    func performTiming(_ build: @escaping (TimingResolution?) throws -> (command: DrillCommand, report: FitReport),
                       resolution: TimingResolution? = nil, then committed: (() -> Void)? = nil) {
        do {
            let result = try build(resolution)
            if perform(result.command) {
                statusMessage = describe(result.report)
                committed?()
            }
        } catch let conflict as TimingEditConflict {
            var labels: [AnchorID: String] = [:]
            for anchor in movement.timing.anchors {
                let position = (try? map?.musicalPosition(at: anchor.cursor).label) ?? "pin"
                labels[anchor.id] = "\(position) @\(TimeFormat.clock(anchor.seconds))"
            }
            self.conflict = PendingConflict(conflict: conflict, anchorLabels: labels) { [weak self] choice in
                self?.conflict = nil
                guard choice != .cancel else { return }
                self?.performTiming(build, resolution: choice, then: committed)
            }
        } catch {
            report(error)
        }
    }

    func describe(_ report: FitReport) -> String {
        guard let last = report.intervals.last else {
            return "Music starts at \(TimeFormat.clock(report.originSeconds))."
        }
        let tempo = last.meanTempo.map { " · mean tempo \(TimeFormat.decimal($0, places: 2)) BPM" } ?? ""
        return "Fitted between pins: scale \(TimeFormat.decimal(last.scale, places: 5))\(tempo)"
    }

    // MARK: Sets and navigation

    func selectSet(_ id: SetID) {
        if id != currentSetID { focusedNoteID = nil }
        currentSetID = id
        alignSetID = id
        if !isPlaying { isBetweenSets = false }
        if let set = show.set(id), let t = try? map?.audioTime(at: set.cursor) {
            playheadSeconds = t
            // While playing this restarts the audio clock at the arrival; otherwise the next tick reads the old time back.
            transport.seek(to: t)
            if isPlaying { lastPlaybackSetIndex = evaluator?.setIndex(atPulse: currentPulse) }
        }
    }

    func stepSet(_ delta: Int) {
        let list = setsInMovement
        // During playback the current set is where play began, so step from the set at the playhead.
        let baseID = isPlaying ? evaluator.map { $0.sets[$0.setIndex(atPulse: currentPulse)].id } ?? currentSetID : currentSetID
        guard let i = list.firstIndex(where: { $0.id == baseID }) else { return }
        let j = min(max(i + delta, 0), list.count - 1)
        selectSet(list[j].id)
    }

    func addSet(counts: Int) {
        let id = SetID()
        perform { try self.show.makeCreateSet(after: self.currentSetID, counts: counts, newSetID: id) }
        if show.set(id) != nil { selectSet(id) }
    }

    func deleteCurrentSet() {
        guard let previous = show.previousSet(before: currentSetID) else {
            report(DrillError("The preset cannot be deleted. Clear its positions instead."))
            return
        }
        if perform(.deleteSet(currentSetID)) { selectSet(previous.id) }
    }

    func setMoveCounts(_ counts: Int) {
        perform { try self.show.makeSetMoveCounts(self.currentSetID, counts: counts) }
    }

    /// Splits the move into `setID` with a subset `count` counts in, then shows the subset.
    func splitMove(into setID: SetID, atCount count: Int) {
        let id = SetID()
        perform { try self.show.makeSplitMove(into: setID, atCount: Rational(count), newSetID: id) }
        guard let subset = show.set(id) else { return }
        selectSet(id)
        statusMessage = "Added subset \(subset.label) at count \(count) of the move."
    }

    /// The move the playhead is inside and the whole count it rests nearest, when between sets.
    var playheadSplit: (setID: SetID, count: Int)? {
        guard isBetweenSets, !isPlaying, let evaluator else { return nil }
        let pulse = currentPulse
        let k = evaluator.setIndex(atPulse: pulse)
        guard k + 1 < evaluator.sets.count else { return nil }
        let count = Int((pulse - evaluator.pulses[k]).rounded())
        guard count > 0, Double(count) < evaluator.pulses[k + 1] - evaluator.pulses[k] else { return nil }
        return (evaluator.sets[k + 1].id, count)
    }

    /// Splits the move under the playhead at the nearest whole count.
    func splitMoveAtPlayhead() {
        guard let split = playheadSplit else {
            report(DrillError("Pause the playhead inside a move, between two sets, to split it there."))
            return
        }
        splitMove(into: split.setID, atCount: split.count)
    }

    func renameCurrentSet(_ label: String) {
        guard let set = currentSet, set.label != label else { return }
        perform(.updateSet(set.id, label: label, notes: set.notes))
    }

    // MARK: Roster and field

    func addSection(name: String, prefix: String, count: Int, symbol: PerformerSymbol) {
        let colorIndex = show.sections.count
        perform { try self.show.makeRoster([RosterSectionRequest(name: name, prefix: prefix, count: count, symbol: symbol, colorIndex: colorIndex)]) }
    }

    func setSectionPrefix(_ id: SectionID, prefix: String) {
        perform { try self.show.makeSectionPrefix(id, prefix: prefix) }
    }

    func setSectionSymbol(_ id: SectionID, symbol: PerformerSymbol) {
        perform { try self.show.makeSectionSymbol(id, symbol: symbol) }
    }

    /// Gives performers their own symbol, or nil to follow their section again.
    func setSymbol(_ ids: [PerformerID], symbol: PerformerSymbol?) {
        let wanted = Set(ids)
        perform { try self.show.makePerformerSymbol(self.show.performers.map(\.id).filter(wanted.contains), symbol: symbol) }
    }

    /// The symbol the canvas draws for a performer, honoring the circles-only preference.
    func displaySymbol(for performer: Performer) -> PerformerSymbol {
        circlesOnly ? .circle : show.symbol(for: performer)
    }

    // MARK: Field notes

    /// The focused note when it is on the current set and the field shows that set.
    var focusedNote: FieldNote? {
        guard showsFieldNotes, let id = focusedNoteID, let note = show.fieldNote(id), note.setID == currentSetID else { return nil }
        return note
    }

    /// Notes belong to a set, so they are hidden during playback and between sets.
    var showsFieldNotes: Bool { !isPlaying && !isBetweenSets }

    func focusNote(_ id: NoteID) {
        selection = []
        focusedNoteID = id
    }

    /// Adds an empty note on the current set and focuses it so its text can be typed in the inspector.
    func addNote() {
        guard isEditable, let set = currentSet else {
            statusMessage = "Select a set to add a note to it."
            return
        }
        let field = show.field
        // Upper left of the field, stepping down for each note so new boxes do not stack exactly.
        let step = Double(show.fieldNotes(on: set.id).count % 6) * 4
        let note = FieldNote(setID: set.id, position: Point2(-field.length / 4, field.width / 4 - step))
        if perform(.addFieldNote(note)) { focusNote(note.id) }
    }

    func moveNote(_ id: NoteID, to position: Point2) {
        perform(.moveFieldNote(id, position))
    }

    func editNote(_ id: NoteID, text: String) {
        if noteDraft?.id == id { noteDraft = nil }
        guard let note = show.fieldNote(id), note.text != text else { return }
        perform(.editFieldNote(id, text))
    }

    func deleteNote(_ id: NoteID) {
        if noteDraft?.id == id { noteDraft = nil }
        if perform(.deleteFieldNote(id)) { focusedNoteID = nil }
    }

    func selectSection(_ id: SectionID) {
        selection = Set(show.performers(in: id).map(\.id))
    }

    func applyField(_ field: Field) {
        perform(.setField(field))
    }

    func keepField() {
        tour.handle(TourEvent.fieldKept)
        TourStore.save(tour)
        statusMessage = "Keeping \(show.field.name)."
    }

    // MARK: Canvas intents

    func commitMove(_ ids: [PerformerID], by delta: Point2) {
        guard isEditable, delta.length > 1e-9 else { return }
        perform { try self.show.makeTranslate(ids, at: self.currentSetID, by: delta) }
    }

    func nudge(dx: Double, dy: Double) {
        guard isEditable, !selection.isEmpty else { return }
        let step = show.field.stepSize
        commitMove(Array(selection), by: Point2(dx * step, dy * step))
    }

    func commitForm(_ geometry: FormGeometry) {
        guard isEditable else { return }
        guard !selection.isEmpty else {
            report(DrillError("Select performers first, then draw the \(geometry.kindName.lowercased())."))
            return
        }
        let members = Array(selection)
        let set = currentSetID
        buildArrangement { try $0.makeForm(geometry, members: members, at: set) }
        // Back to Select so the next click picks performers instead of drawing again.
        tool = .select
    }

    /// Performers without a position on the current set.
    var unplacedCount: Int {
        let formation = show.formation(currentSetID)
        return show.performers.filter { formation[$0.id] == .unresolved }.count
    }

    func placeSelection(in shape: QuickShape) {
        guard isEditable else {
            statusMessage = "Select a set to arrange performers."
            return
        }
        let members = Array(selection), set = currentSetID, spacing = shapeSpacingSteps
        buildArrangement { try $0.makeQuickShape(shape, members: members, at: set, spacingSteps: spacing) }
        tool = .select
    }

    /// Spells the text box's text with the selection, centered where they stand.
    func placeSelectionInText() {
        guard isEditable else {
            statusMessage = "Select a set to arrange performers."
            return
        }
        let members = Array(selection), set = currentSetID, spacing = shapeSpacingSteps, text = shapeText
        buildArrangement { try $0.makeQuickText(text, members: members, at: set, spacingSteps: spacing) }
        tool = .select
    }

    /// The Text tool: spells the text along the dragged baseline with the selection.
    func commitText(from start: Point2, to end: Point2) {
        guard isEditable else { return }
        guard !selection.isEmpty else {
            report(DrillError("Select performers first, then drag on the field to spell the text."))
            return
        }
        do {
            let text = try TextShape.validated(shapeText)
            let members = Array(selection), set = currentSetID, shape = TextShape(text, start: start, end: end)
            buildArrangement { try $0.makeDrawnSet([.text(shape)], members: members, at: set, name: "Spell \(text)") }
            tool = .select
        } catch {
            report(error)
        }
    }

    func placeUnplaced() {
        guard isEditable else {
            statusMessage = "Select a set to place performers."
            return
        }
        let set = currentSetID, spacing = shapeSpacingSteps
        buildArrangement({ try $0.makePlaceUnplaced(at: set, spacingSteps: spacing) }) { [weak self] in
            self?.requestCanvas(.fitField)
        }
    }

    /// Build from a value snapshot away from AppKit. Only a current, completed
    /// result may enter the document's normal atomic command/undo pipeline.
    func buildArrangement(_ build: @escaping @Sendable (Show) throws -> DrillCommand,
                          completion: @escaping @MainActor () -> Void = {}) {
        guard isEditable else { return }
        let snapshot = show, startingRevision = session.revision, set = currentSetID, members = selection
        let generation = UUID()
        arrangementGeneration = generation
        isArranging = true
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let command = try build(snapshot)
            try Task.checkCancellation()
            return command
        }
        arrangementTask = worker
        Task { [weak self] in
            do {
                let command = try await worker.value
                guard let self, self.arrangementGeneration == generation else { return }
                self.arrangementTask = nil
                self.isArranging = false
                guard !worker.isCancelled, self.session.revision == startingRevision,
                      self.currentSetID == set, self.selection == members, self.isEditable else { return }
                if self.perform(command) { completion() }
            } catch {
                guard let self, self.arrangementGeneration == generation else { return }
                self.arrangementTask = nil
                self.isArranging = false
                if !worker.isCancelled { self.report(error) }
            }
        }
    }

    func cancelArrangement() {
        guard isArranging else { return }
        arrangementTask?.cancel()
        arrangementTask = nil
        arrangementGeneration = UUID()
        isArranging = false
    }

    // MARK: Draw Next Set

    /// Adds a set after the current one and starts drawing its shapes. The set
    /// copies the current formation, so anyone left out of the route stays put.
    func drawNextSet(counts: Int = 16) {
        guard isEditable else {
            statusMessage = "Select a set to draw the next one after it."
            return
        }
        let id = SetID()
        perform { try self.show.makeCreateSet(after: self.currentSetID, counts: counts, newSetID: id) }
        guard let set = show.set(id) else { return }
        selectSet(id)
        selection = []
        focusedNoteID = nil
        tool = .select
        draft = SetDraft(setID: id, sections: Set(show.sections.map(\.id)))
        statusMessage = "Draw the shapes for set \(set.label), then choose Auto Route."
    }

    /// Performers in the draft's chosen sections, in roster order.
    var draftMembers: [PerformerID] {
        guard let draft else { return [] }
        return show.performers.filter { draft.sections.contains($0.sectionID) }.map(\.id)
    }

    func addDraftShape(_ shape: DrawnShape) {
        guard draft != nil else { return }
        do {
            var shape = shape
            if case .text(var text) = shape {
                text.text = try TextShape.validated(text.text)
                shape = .text(text)
            }
            try shape.validate()
            draft?.shapes.append(shape)
        } catch {
            report(error)
        }
    }

    func removeLastDraftShape() {
        guard draft?.shapes.isEmpty == false else { return }
        draft?.shapes.removeLast()
    }

    func clearDraftShapes() { draft?.shapes = [] }

    func toggleDraftSection(_ id: SectionID) {
        guard let draft else { return }
        if draft.sections.contains(id) { self.draft?.sections.remove(id) } else { self.draft?.sections.insert(id) }
    }

    /// Where the chosen performers would stand, or why the shapes cannot hold them.
    var draftPreview: Result<[Point2], DrillError> {
        guard let draft, !draft.shapes.isEmpty else { return .success([]) }
        let members = draftMembers
        if let cached = draftPreviewCache, cached.revision == session.revision, cached.shapes == draft.shapes, cached.members == members {
            return cached.result
        }
        let result: Result<[Point2], DrillError>
        do {
            result = .success(try show.drawnTargets(draft.shapes, count: members.count).flatMap { $0 })
        } catch let error as DrillError {
            result = .failure(error)
        } catch {
            result = .failure(DrillError("\(error)"))
        }
        draftPreviewCache = (session.revision, draft.shapes, members, result)
        return result
    }

    /// Fills the drawn shapes with the chosen sections using the usual shortest-move
    /// assignment, as one undoable change. Everyone else stands where they were.
    func autoRouteDraft() {
        guard let draft, draft.setID == currentSetID else { return }
        guard !draft.shapes.isEmpty else {
            report(DrillError("Draw at least one shape first."))
            return
        }
        if case .failure(let error) = draftPreview {
            report(error)
            return
        }
        let members = draftMembers, shapes = draft.shapes, set = draft.setID
        buildArrangement({ try $0.makeDrawnSet(shapes, members: members, at: set, holdOthers: true) }) { [weak self] in
            guard let self else { return }
            self.draft?.routed = true
            let plural = shapes.count == 1 ? "" : "s"
            self.statusMessage = "Routed \(members.count) performers into \(shapes.count) shape\(plural). Change the shapes and route again, or choose Done."
        }
    }

    func finishDraft() {
        guard draft != nil else { return }
        draft = nil
        statusMessage = nil
    }

    func commitHandle(_ formID: FormID, geometry: FormGeometry) {
        guard isEditable else { return }
        perform(.updateFormGeometry(formID, geometry))
    }

    func reverseForm(_ formID: FormID) {
        guard let form = show.form(formID) else { return }
        perform(.updateFormMembers(formID, form.members.reversed()))
    }

    func detachForm(_ formID: FormID) { perform(.detachForm(formID)) }

    // MARK: Paths

    /// The move into the current set, which paths edit; nil on the preset.
    var currentMove: (transition: Transition, from: ArrivalSet, counts: Rational)? { try? show.move(into: currentSetID) }

    func commitWaypointMove(_ id: PerformerID, segment: Int, to point: Point2) {
        guard isEditable else { return }
        perform { try self.show.makeMoveWaypoint(into: self.currentSetID, performer: id, segment: segment, to: point) }
    }

    func commitWaypointInsert(_ id: PerformerID, atCount count: Rational, at point: Point2) {
        guard isEditable else { return }
        perform { try self.show.makeInsertWaypoint(into: self.currentSetID, performer: id, atCount: count, at: point) }
    }

    func deleteWaypoint(_ id: PerformerID, segment: Int) {
        guard isEditable else { return }
        perform { try self.show.makeDeleteWaypoint(into: self.currentSetID, performer: id, segment: segment) }
    }

    /// Bends a leg into an arc; within a quarter step of straight it snaps back to a line.
    func commitCurveLeg(_ id: PerformerID, segment: Int, sagitta: Double, snaps: Bool) {
        guard isEditable else { return }
        let snap = snaps ? show.field.stepSize / 4 : 0
        perform { try self.show.makeCurveLeg(into: self.currentSetID, performer: id, segment: segment, sagitta: sagitta, snap: snap) }
    }

    /// "Start late by n counts" (start) and "Arrive early by n counts" (end) for the selection; nil keeps that hold.
    func setHolds(start: Rational?, end: Rational?) {
        guard isEditable else { return }
        perform { try self.show.makeHoldPhases(into: self.currentSetID, performers: Array(self.selection), startHold: start, endHold: end) }
    }

    func evenPaceSelection() {
        guard isEditable else { return }
        perform { try self.show.makeEvenPace(into: self.currentSetID, performers: Array(self.selection)) }
    }

    func straightenSelection() {
        guard isEditable else { return }
        perform { try self.show.makeStraighten(into: self.currentSetID, performers: Array(self.selection)) }
    }

    func setCoordinate(_ id: PerformerID, x: Double, y: Double) {
        perform { try self.show.makeSetCoordinate(id, at: self.currentSetID, x: x, y: y) }
    }

    func setPlacementUnresolved(_ ids: [PerformerID]) {
        perform(.setPlacements(currentSetID, Dictionary(uniqueKeysWithValues: ids.map { ($0, Placement.unresolved) })))
    }

    func selectAll() { selection = Set(show.performers.map(\.id)) }

    // MARK: Timing

    func configureTimeline(numerator: Int, denominator: Int, bpm: Double, pulse: Rational?, measures: Int) {
        perform { try self.show.makeConfigureTimeline(movementID: self.movementID, meter: Meter(numerator, denominator), bpm: bpm, pulseUnit: pulse, measures: measures) }
    }

    func setTempo(firstMeasure: Int, lastMeasure: Int, bpm: Double) {
        let indices = movement.timing.measures.enumerated().filter { $0.element.number >= firstMeasure && $0.element.number <= lastMeasure }.map(\.offset)
        guard let lo = indices.first, let hi = indices.last else {
            report(DrillError("Those measures are not in the timeline."))
            return
        }
        let movementID = self.movementID
        performTiming { resolution in try self.show.makeTempo(movementID: movementID, measures: lo...hi, bpm: bpm, resolution: resolution) }
    }

    /// Counts-only tempo: applies to the whole measures that the move into the
    /// current set spans, so designers never have to think in measure numbers.
    func setTempoForCurrentMove(bpm: Double) {
        guard let map, let set = currentSet, let previous = show.previousSet(before: set.id) else {
            report(DrillError("Choose a set after the opening set to change the tempo of its move."))
            return
        }
        do {
            let start = try map.musicalPosition(at: previous.cursor)
            let end = try map.musicalPosition(at: set.cursor)
            let endsOnDownbeat = end.beat == 1 && end.beatFraction.isZero && end.holdOffsetSeconds == nil
            let lo = start.measureIndex, hi = max(lo, endsOnDownbeat ? end.measureIndex - 1 : end.measureIndex)
            let movementID = self.movementID
            performTiming { resolution in try self.show.makeTempo(movementID: movementID, measures: lo...hi, bpm: bpm, resolution: resolution) }
        } catch {
            report(error)
        }
    }

    func setCurrentSetMarkers(rehearsalMark: String, measureMarker: String) {
        guard let set = currentSet, set.rehearsalMark != rehearsalMark || set.measureMarker != measureMarker else { return }
        perform(.updateSetMarkers(set.id, rehearsalMark: rehearsalMark, measureMarker: measureMarker))
    }

    func setCountingMode(_ mode: CountingMode) {
        guard show.countingMode != mode else { return }
        perform(.setCountingMode(mode))
    }

    func setFitMode(_ mode: FitMode) {
        var track = movement.timing
        guard track.fitMode != mode else { return }
        track.fitMode = mode
        perform(.batch(mode == .preserveAudioPins ? "Preserve Audio Pins" : "Preserve Notated Tempo", [.replaceTiming(movementID, track)]))
    }

    private func playheadFrame() throws -> Int64 {
        guard let asset = audioAsset else { throw DrillError("Import audio before aligning music.") }
        guard playheadSeconds >= 0 else { throw DrillError("Move the playhead into the audio before aligning.") }
        return Int64((playheadSeconds * asset.sampleRate).rounded())
    }

    /// "Align measure/beat here".
    func alignHere(measure: Int, beat: Int) {
        do {
            let frame = try playheadFrame()
            guard let cursor = try map?.cursor(measureNumber: measure, beat: beat) else { return }
            let movementID = self.movementID
            performTiming { resolution in try self.show.makeAlignHere(movementID: movementID, cursor: cursor, sampleFrame: frame, resolution: resolution) }
        } catch { report(error) }
    }

    /// "Align selected set arrival here": pins the set the user chose, not the one
    /// the old timing happened to place at the playhead.
    func alignSelectedSetHere() {
        do {
            let frame = try playheadFrame()
            let setID = alignSetID
            performTiming({ resolution in try self.show.makeAlignSetArrival(setID, sampleFrame: frame, resolution: resolution) }) {
                // The set now arrives at the playhead, so show it and keep it editable.
                self.currentSetID = setID
                self.isBetweenSets = false
            }
        } catch { report(error) }
    }

    func moveAnchor(_ id: AnchorID, toSeconds seconds: Double) {
        guard let asset = audioAsset else { return }
        let frame = Int64((max(0, seconds) * asset.sampleRate).rounded())
        let movementID = self.movementID
        performTiming { _ in try self.show.makeMoveAnchor(movementID: movementID, anchorID: id, sampleFrame: frame) }
    }

    func removeAnchor(_ id: AnchorID) {
        perform { try self.show.makeRemoveAnchor(movementID: self.movementID, anchorID: id) }
    }

    func countsOnly() {
        tour.handle(TourEvent.countsOnly)
        TourStore.save(tour)
        statusMessage = "No music: playback follows the tempo."
    }

    // MARK: Audio

    func importAudio(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard let container = AudioSniffer.detect(data) else {
                throw DrillError("\(url.lastPathComponent) is not a WAV or MP3 file.")
            }
            let decoded = try AudioDecoder.decode(url: url)
            guard var document = document?.currentDocumentSnapshot() else { return }
            let info = document.embed(data, fileExtension: container.rawValue, originalFilename: url.lastPathComponent,
                                      sampleRate: decoded.sampleRate, frameCount: decoded.frameCount, channelCount: decoded.channelCount)
            assets[info.archivePath] = data
            self.document?.recordAsset(path: info.archivePath, data: data)
            perform { try self.show.makeImportAudio(info, movementID: self.movementID) }
        } catch {
            report(error)
        }
    }

    func loadAudioForCurrentMovement() {
        let generation = UUID()
        audioLoadGeneration = generation
        transport.stop()
        peaks = nil
        guard let asset = audioAsset, let data = assets[asset.archivePath] else {
            audioStatus = hasAudio ? "Audio missing" : "No audio"
            transport.unload()
            return
        }
        audioStatus = "Decoding \(asset.originalFilename)…"
        do {
            let url = try AudioDecoder.materialize(data, name: asset.archivePath.replacingOccurrences(of: "/", with: "-"))
            try transport.load(url: url)
            let name = asset.originalFilename
            Task.detached(priority: .userInitiated) {
                let result = Result {
                    let pcm = try AudioDecoder.decode(url: url)
                    return (peaks: WaveformPeaks(audio: pcm), duration: pcm.duration, sampleRate: pcm.sampleRate)
                }
                await MainActor.run {
                    guard self.audioLoadGeneration == generation else { return }
                    switch result {
                    case .success(let audio):
                        self.peaks = audio.peaks
                        self.audioStatus = "\(name) · \(TimeFormat.clock(audio.duration)) · \(Int(audio.sampleRate)) Hz"
                    case .failure(let error):
                        self.audioStatus = "Could not decode \(name): \(error.localizedDescription)"
                    }
                }
            }
        } catch {
            audioStatus = "Could not open audio: \(error.localizedDescription)"
        }
    }

    // MARK: Playback

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        isBetweenSets = true
        transport.play(from: playheadSeconds)
        isPlaying = true
        lastPlaybackSetIndex = evaluator?.setIndex(atPulse: currentPulse)
        startDisplayRefresh()
    }

    /// The view's display link follows its screen and stops requesting frames while hidden.
    func attachPlaybackView(_ view: NSView) {
        playbackView = view
        if isPlaying { startDisplayRefresh() }
    }

    private func startDisplayRefresh() {
        stopDisplayRefresh()
        if let playbackView {
            let target = PlaybackDisplayTarget { [weak self] in self?.tick() }
            displayTarget = target
            let link = playbackView.displayLink(target: target, selector: #selector(PlaybackDisplayTarget.refresh))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            // Headless clients have no display. This refresh still only samples the media clock.
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            displayTimer = timer
        }
    }

    private func stopDisplayRefresh() {
        displayLink?.invalidate()
        displayLink = nil
        displayTarget = nil
        displayTimer?.invalidate()
        displayTimer = nil
    }

    func pause() {
        transport.pause()
        playheadSeconds = transport.currentTime
        isPlaying = false
        playbackPosition.update(playheadSeconds, continuously: false)
        stopDisplayRefresh()
        if wholeCountsOnly, let map {
            let location = map.locate(audioTime: playheadSeconds)
            // Keep pre-roll and elapsed holds intact when already on a whole count.
            if !location.isPreRoll, !location.isPastEnd,
               abs(location.pulse - location.pulse.rounded()) > 1e-6 {
                let count = min(location.pulse.rounded(), floor(map.totalPulses.doubleValue))
                if let time = try? map.audioTime(atPulse: Rational(Int64(count))) {
                    playheadSeconds = time
                    transport.seek(to: time)
                }
            }
        }
        snapToSetIfAtArrival()
    }

    func seek(to seconds: Double) {
        playheadSeconds = seconds
        transport.seek(to: seconds)
        if !isPlaying { snapToSetIfAtArrival() }
    }

    private func tick() {
        guard isPlaying else { return }
        playheadSeconds = transport.currentTime
        if playheadSeconds > timelineDuration + 1 { pause(); return }
        guard let evaluator else { return }
        let index = evaluator.setIndex(atPulse: currentPulse)
        if let last = lastPlaybackSetIndex, index != last,
           tour.currentStep?.requirements.contains(where: { $0.contains(TourEvent.playbackCrossedSet) }) == true {
            tour.handle(TourEvent.playbackCrossedSet)
            TourStore.save(tour)
        }
        lastPlaybackSetIndex = index
    }

    /// When the playhead rests on an arrival, that set becomes editable again.
    func snapToSetIfAtArrival() {
        guard let evaluator else { return }
        let pulse = currentPulse
        let index = evaluator.setIndex(atPulse: pulse)
        currentSetID = evaluator.sets[index].id
        isBetweenSets = abs(evaluator.pulses[index] - pulse) > 1e-6
    }

    // MARK: Export

    func coordinatePDF(options: CoordinateExportOptions) throws -> Data {
        let data = try CoordinateSheet.render(show, movementID: movementID, options: options)
        tour.handle(TourEvent.pdfPreviewed)
        TourStore.save(tour)
        return data
    }

    /// Analysis results, recomputed once per revision.
    var analysisIssues: [DrillIssue] {
        if let cached = analysisCache, cached.revision == session.revision { return cached.issues }
        let issues = (try? DrillAnalyzer.analyze(show, movementID: movementID, map: map)) ?? []
        analysisCache = (session.revision, issues)
        return issues
    }

    // MARK: Tour

    func restartTour() {
        tour.restart()
        TourStore.save(tour)
    }

    func tourBack() { tour.back(); TourStore.save(tour) }
    func tourSkip() { tour.skip(); TourStore.save(tour) }
    func tourDismiss() { tour.dismiss(); TourStore.save(tour) }
}

/// Per-user tour progress in UserDefaults, keyed by tour version. Never in documents.
enum TourStore {
    static let key = "FieldworkTourProgress.v\(Tour.currentVersion)"

    static func load() -> Tour {
        guard let data = UserDefaults.standard.data(forKey: key),
              let progress = try? JSONDecoder().decode(TourProgress.self, from: data) else { return Tour() }
        return Tour(progress: progress)
    }

    static func save(_ tour: Tour) {
        if let data = try? JSONEncoder().encode(tour.progress) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Only time readouts and native drawing surfaces subscribe to the display clock.
@MainActor
final class PlaybackPosition: ObservableObject {
    private(set) var seconds: Double = 0
    let frames = PassthroughSubject<Double, Never>()
    @Published private(set) var readoutSeconds: Double = 0
    private var lastReadoutTime: CFTimeInterval = 0

    func update(_ seconds: Double, continuously: Bool) {
        self.seconds = seconds
        frames.send(seconds)
        // Text entry and musical labels need fewer layout passes than moving dots.
        let now = CACurrentMediaTime()
        if !continuously || now - lastReadoutTime >= 0.1 {
            lastReadoutTime = now
            readoutSeconds = seconds
        }
    }
}

/// The display link retains its target; the callback captures the editor weakly.
@MainActor
private final class PlaybackDisplayTarget: NSObject {
    let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
    @objc func refresh() { callback() }
}

extension EditorModel {
    /// Shows one-based marching counts within the move, using cached set pulses.
    func moveCountLabel(atPulse pulse: Double, places: Int) -> String {
        guard let evaluator, !evaluator.sets.isEmpty else { return "" }
        let index = evaluator.setIndex(atPulse: pulse)
        let from = evaluator.sets[index].label
        guard index + 1 < evaluator.sets.count,
              pulse > evaluator.pulses[index] + 1e-9 else {
            return "Set \(from)"
        }
        let elapsed = max(0, pulse - evaluator.pulses[index])
        let duration = evaluator.pulses[index + 1] - evaluator.pulses[index]
        let marchingCount = min(elapsed + 1, duration)
        let count = wholeCountsOnly
            ? TimeFormat.decimal(max(1, floor(marchingCount + 1e-6)), places: 0)
            : TimeFormat.decimal(marchingCount, places: places)
        let unit = count == "1" || Double(count) == 1 ? "count" : "counts"
        return "\(count) \(unit) · Set \(from) → \(evaluator.sets[index + 1].label)"
    }
}
