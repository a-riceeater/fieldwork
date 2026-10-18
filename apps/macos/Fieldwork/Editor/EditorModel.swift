import AppKit
import Combine
import DrillTiming
import DrillCore
import DrillDocument
import DrillMedia
import DrillExport
import FieldworkTour

enum EditorTool: String, CaseIterable, Identifiable {
    case select, line, arc
    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: return "Select"
        case .line: return "Line"
        case .arc: return "Arc"
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .line: return "line.diagonal"
        case .arc: return "circle.bottomhalf.filled"
        }
    }
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
    @Published var selection: Set<PerformerID> = []
    @Published var currentSetID: SetID
    @Published var tool: EditorTool = .select
    @Published var snapEnabled = true
    @Published var snapSteps: Double = 1
    @Published var axisLock: AxisLock = .none
    @Published var playheadSeconds: Double = 0
    /// True while the canvas shows an interpolated frame between sets.
    @Published var isBetweenSets = false
    @Published private(set) var isPlaying = false
    @Published var playbackRate: Double = 1 { didSet { transport.rate = playbackRate } }
    @Published var wholeCountsOnly: Bool {
        didSet { preferences.set(wholeCountsOnly, forKey: "FieldworkWholeCountsOnly") }
    }
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
    private var lastPlaybackSetIndex: Int?
    private var evaluatorCache: (revision: Int, evaluator: SceneEvaluator)?
    private var analysisCache: (revision: Int, issues: [DrillIssue])?

    init(session: DocumentSession, assets: [String: Data], readOnlyReason: String? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        wholeCountsOnly = preferences.bool(forKey: "FieldworkWholeCountsOnly")
        self.session = session
        self.assets = assets
        self.readOnlyReason = readOnlyReason
        currentSetID = session.show.sets[0].id
        tour = TourStore.load()
        revision = session.revision
        loadAudioForCurrentMovement()
    }

    // MARK: Model access

    var show: Show { session.show }
    var movementID: MovementID { show.movements[0].id }
    var movement: Movement { show.movements[0] }
    var map: TimingMap? { try? session.timingMap(for: movementID) }
    var hasAudio: Bool { movement.audioAssetID != nil }
    var isEditable: Bool { readOnlyReason == nil && !isPlaying && !isBetweenSets }
    var currentSet: ArrivalSet? { show.set(currentSetID) }
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
        revision = session.revision
        document?.didCommit(event)
        if event.action == .perform {
            tour.handle(event.command.allKinds)
            TourStore.save(tour)
        }
        if show.set(currentSetID) == nil { currentSetID = setsInMovement.last?.id ?? show.sets[0].id }
        selection = selection.filter { show.performer($0) != nil }
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
    func performTiming(_ build: @escaping (TimingResolution?) throws -> (command: DrillCommand, report: FitReport), resolution: TimingResolution? = nil) {
        do {
            let result = try build(resolution)
            if perform(result.command) { statusMessage = describe(result.report) }
        } catch let conflict as TimingEditConflict {
            var labels: [AnchorID: String] = [:]
            for anchor in movement.timing.anchors {
                let position = (try? map?.musicalPosition(at: anchor.cursor).label) ?? "pin"
                labels[anchor.id] = "\(position) @\(TimeFormat.clock(anchor.seconds))"
            }
            self.conflict = PendingConflict(conflict: conflict, anchorLabels: labels) { [weak self] choice in
                self?.conflict = nil
                guard choice != .cancel else { return }
                self?.performTiming(build, resolution: choice)
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
        currentSetID = id
        isBetweenSets = false
        if let set = show.set(id), let t = try? map?.audioTime(at: set.cursor) {
            playheadSeconds = t
            if !isPlaying { transport.seek(to: t) }
        }
    }

    func stepSet(_ delta: Int) {
        let list = setsInMovement
        guard let i = list.firstIndex(where: { $0.id == currentSetID }) else { return }
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
        let members = show.sequentialOrder(Array(selection))
        perform { try self.show.makeForm(geometry, members: members, at: self.currentSetID) }
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

    /// "Align selected set arrival here".
    func alignCurrentSetHere() {
        do {
            let frame = try playheadFrame()
            let setID = currentSetID
            performTiming { resolution in try self.show.makeAlignSetArrival(setID, sampleFrame: frame, resolution: resolution) }
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
                let result = Result { try AudioDecoder.decode(url: url) }
                await MainActor.run {
                    switch result {
                    case .success(let pcm):
                        self.peaks = WaveformPeaks(audio: pcm)
                        self.audioStatus = "\(name) · \(TimeFormat.clock(pcm.duration)) · \(Int(pcm.sampleRate)) Hz"
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
        displayTimer?.invalidate()
        // Display-only refresh: it asks the audio clock what time it is and never advances time itself.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    func pause() {
        transport.pause()
        playheadSeconds = transport.currentTime
        isPlaying = false
        displayTimer?.invalidate()
        displayTimer = nil
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
        if let last = lastPlaybackSetIndex, index != last {
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
