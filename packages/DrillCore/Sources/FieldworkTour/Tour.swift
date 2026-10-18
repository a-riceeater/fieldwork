/// Onboarding coach-mark tour. This is per-user view state; it is never
/// stored in a show document. Steps advance only on observed successful
/// actions (command kinds or explicit UI events), never on timers.
public struct TourStep: Hashable, Sendable, Identifiable {
    public var id: String
    /// Semantic accessibility identifier of the anchored control.
    public var targetID: String
    public var title: String
    /// At most two short sentences.
    public var body: String
    /// All groups must be satisfied; any event within a group satisfies it.
    public var requirements: [Set<String>]
    /// Shown in an inspector card when the target is offscreen or hidden.
    public var fallback: String

    public init(id: String, targetID: String, title: String, body: String, requirements: [Set<String>], fallback: String) {
        self.id = id
        self.targetID = targetID
        self.title = title
        self.body = body
        self.requirements = requirements
        self.fallback = fallback
    }
}

public struct TourProgress: Hashable, Codable, Sendable {
    public var version: Int
    public var stepIndex: Int
    /// Requirement groups already satisfied for the current step.
    public var satisfied: [Int]
    public var finished: Bool
    public var dismissed: Bool

    public init(version: Int) {
        self.version = version
        stepIndex = 0
        satisfied = []
        finished = false
        dismissed = false
    }
}

/// Well-known UI events that are not drill commands.
public enum TourEvent {
    public static let fieldKept = "ui.fieldKept"
    public static let countsOnly = "ui.countsOnly"
    public static let playbackCrossedSet = "ui.playbackCrossedSet"
    public static let pdfPreviewed = "ui.pdfPreviewed"
}

public struct Tour: Sendable {
    public static let currentVersion = 1

    public let steps: [TourStep]
    public private(set) var progress: TourProgress

    public init(steps: [TourStep] = Tour.gettingStarted, progress: TourProgress? = nil) {
        self.steps = steps
        if let progress, progress.version == Tour.currentVersion, progress.stepIndex <= steps.count {
            self.progress = progress
        } else {
            self.progress = TourProgress(version: Tour.currentVersion)
        }
    }

    public var isActive: Bool { !progress.finished && !progress.dismissed && progress.stepIndex < steps.count }
    public var currentStep: TourStep? { isActive ? steps[progress.stepIndex] : nil }
    public var canGoBack: Bool { isActive && progress.stepIndex > 0 }

    /// Feeds an observed event. Returns true when the current step completed.
    @discardableResult
    public mutating func handle(_ event: String) -> Bool {
        guard let step = currentStep else { return false }
        for (i, group) in step.requirements.enumerated() where group.contains(event) && !progress.satisfied.contains(i) {
            progress.satisfied.append(i)
        }
        guard progress.satisfied.count == step.requirements.count else { return false }
        advance()
        return true
    }

    public mutating func handle(_ events: [String]) {
        for event in events { handle(event) }
    }

    /// Skip moves to the next step without marking work done.
    public mutating func skip() {
        guard isActive else { return }
        advance()
    }

    public mutating func back() {
        guard canGoBack else { return }
        progress.stepIndex -= 1
        progress.satisfied = []
    }

    /// Escape / Close: hide the tour; Help → Getting Started can restart it.
    public mutating func dismiss() { progress.dismissed = true }

    /// Help → Getting Started. Resets tour progress only.
    public mutating func restart() { progress = TourProgress(version: Tour.currentVersion) }

    private mutating func advance() {
        progress.stepIndex += 1
        progress.satisfied = []
        if progress.stepIndex >= steps.count { progress.finished = true }
    }

    /// The eight getting-started steps from the design specification.
    public static let gettingStarted: [TourStep] = [
        TourStep(id: "roster", targetID: "roster.add", title: "Add your ensemble",
                 body: "Add a section of performers. Each gets a stable drill label.",
                 requirements: [["addPerformers"]], fallback: "Open the Roster tab and choose Add Section."),
        TourStep(id: "field", targetID: "field.selector", title: "Choose a field",
                 body: "Pick a field preset or keep the current one.",
                 requirements: [["setField", TourEvent.fieldKept]], fallback: "Field settings are in the inspector when nothing is selected."),
        TourStep(id: "audio", targetID: "timeline.importAudio", title: "Add music",
                 body: "Import a WAV or MP3, or continue with counts only.",
                 requirements: [["addMediaAsset", TourEvent.countsOnly]], fallback: "Use File → Import Audio, or choose Counts Only in the timeline."),
        TourStep(id: "align", targetID: "timeline.alignHere", title: "Align the downbeat",
                 body: "Move the playhead to the first entrance, then press Align Here.",
                 requirements: [["replaceTiming", TourEvent.countsOnly]], fallback: "Align Here is in the timeline toolbar."),
        TourStep(id: "form", targetID: "toolbar.forms", title: "Draw a form",
                 body: "Select performers, choose Line or Arc, and drag on the field.",
                 requirements: [["applyForm"]], fallback: "Line and Arc tools are in the toolbar."),
        TourStep(id: "set", targetID: "navigator.addSet", title: "Add a set",
                 body: "Add a set, then move the formation to its next picture.",
                 requirements: [["createSet"], ["setPlacements", "applyForm", "updateFormGeometry"]], fallback: "Use Set → Add Set, then drag performers."),
        TourStep(id: "play", targetID: "transport.play", title: "Play it back",
                 body: "Press Play and watch the move into the new set.",
                 requirements: [[TourEvent.playbackCrossedSet]], fallback: "Press Space to play from the playhead."),
        TourStep(id: "export", targetID: "toolbar.export", title: "Print coordinates",
                 body: "Preview a coordinate sheet for rehearsal.",
                 requirements: [[TourEvent.pdfPreviewed]], fallback: "Use File → Export Coordinates."),
    ]
}
