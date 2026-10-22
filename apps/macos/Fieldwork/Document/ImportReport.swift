import Foundation
import DrillConvert

/// What a drill import produced, shown once over the newly converted show.
struct ImportReport: Identifiable {
    struct SavedFile: Hashable {
        /// What the file is for, such as "Count track".
        var role: String
        var name: String
    }

    /// What is needed to rewrite the count track and click check with another
    /// audio offset, such as the converter's own unconfident guess.
    struct Realignment {
        var source: URL
        var options: ConverterOptions
        var musicXML: URL
        var clickCheck: URL?

        /// Converts the count track again with count 0 at `offset` seconds into
        /// the recording and replaces the saved count track and click check.
        @MainActor
        func apply(offset: Double) async throws {
            var options = self.options
            options.audioOffset = offset
            let score = try await ThreeDUConverterService().convert(source, to: .musicxml, options: options)
            try DrillImportModel.write(score.data, to: musicXML)
            if let clickCheck, let wav = score.clickCheck { try DrillImportModel.write(wav, to: clickCheck) }
        }
    }

    let id = UUID()
    var sourceName: String
    var savedFiles: [SavedFile]
    var notes: [ImportNote]
    var realignment: Realignment?

    init(sourceName: String, savedFiles: [SavedFile] = [], diagnostics: [ConverterDiagnostic], realignment: Realignment? = nil) {
        self.sourceName = sourceName
        self.savedFiles = savedFiles
        notes = diagnostics.map(ImportNote.init)
        self.realignment = realignment
    }

    /// Notes about something lost, guessed or worth listening to, most serious first.
    var needsAttention: [ImportNote] { notes.filter { $0.kind != .info }.sorted { $0.kind.rawValue < $1.kind.rawValue } }
    var forYourInformation: [ImportNote] { notes.filter { $0.kind == .info } }

    /// The converter's own wording, for bug reports.
    var technicalText: String {
        notes.map { "[\($0.code)] \($0.technical)" }.joined(separator: "\n")
    }
}

/// One converter diagnostic, retold in plain language. The converter's own
/// message is kept as `technical`.
struct ImportNote: Identifiable, Hashable {
    enum Kind: Int {
        /// Something in the original could not be kept as it was.
        case changed
        /// Fieldwork made a guess worth checking.
        case check
        /// Nothing to do.
        case info
    }

    let id = UUID()
    var kind: Kind
    var code: String
    var title: String
    var detail: String
    var systemImage: String
    var technical: String
    /// The converter's best-guess audio offset, when it was not confident enough to use it.
    var suggestedOffset: Double?
    /// The same offset in words, such as "0.53 seconds".
    var suggestedOffsetText: String?

    init(_ diagnostic: ConverterDiagnostic) {
        code = diagnostic.code
        technical = diagnostic.message
        switch diagnostic.severity {
        case "lossy": kind = .changed
        case "info": kind = .info
        default: kind = .check
        }
        let text = Translation(diagnostic.message)
        let n = text.number(0)
        switch diagnostic.code {
        case "alignment_not_confident":
            systemImage = "waveform.badge.magnifyingglass"
            title = "The music may not line up"
            var detail = "Fieldwork couldn't confidently match the drill to the recording, so count 0 starts at the very beginning of the audio."
            if let offset = text.capture(#"best offset ([+-]?[0-9.]+) s"#).flatMap(Double.init), abs(offset) >= 0.001 {
                detail += " Its best guess was that the music starts \(Translation.seconds(abs(offset))) \(offset > 0 ? "later" : "earlier")."
                suggestedOffset = offset
                suggestedOffsetText = Translation.seconds(offset)
            }
            self.detail = detail + " Listen to the click check before relying on the timing."
        case "beat_tracking_not_confident":
            systemImage = "metronome"
            title = "Followed tempos may be off"
            detail = "Fieldwork tried to follow the recording's tempo changes but couldn't confirm them. Listen to the click check before relying on the timing."
        case "audio_starts_late":
            systemImage = "waveform"
            title = "The recording starts after the music"
            let late = text.capture(#"starts ([0-9.]+) s"#).flatMap(Double.init).map(Translation.seconds) ?? "a moment"
            detail = "The recording begins \(late) after the first beat, so measure 1 can't line up with it."
        case "audio_shorter_than_drill":
            systemImage = "waveform"
            title = "The recording is shorter than the drill"
            let extra = text.capture(#"ends ([0-9.]+) s"#).flatMap(Double.init).map(Translation.seconds) ?? "a while"
            detail = "The drill keeps going for \(extra) after the recording ends."
        case "no_audio":
            systemImage = "waveform.slash"
            title = "No recording was used"
            detail = "Count 0 is placed at the start. Import the recording later to line the music up."
        case "audio_reference_only":
            systemImage = "music.note"
            title = "The music isn't included"
            detail = "The drill names its music file but doesn't contain the audio. Use Import Audio to add the recording."
        case "measure_numbers_filled":
            systemImage = "music.note.list"
            let list = text.capture(#"measure\(s\) (.+?) were missing"#).map(Translation.ranges) ?? ""
            let several = list.contains(",") || list.contains("–")
            title = "Missing measure numbers were filled in"
            detail = "\(several ? "Measures" : "Measure") \(list) \(several ? "weren't" : "wasn't") labeled on any set, so Fieldwork filled \(several ? "them" : "it") in to keep the counts even."
        case "bar_lines_estimated":
            systemImage = "music.note.list"
            let list = text.capture(#"measures (.+?) do not divide"#).map(Translation.ranges) ?? "Some measures"
            title = "Some bar lines are estimated"
            detail = "Measures \(list) don't split evenly into their counts, so the bar lines inside them are a best guess."
        case "uneven_measure_spans":
            systemImage = "music.note.list"
            title = "Some measures don't split evenly"
            detail = "\(Translation.count(n, "measure range")) \(n == 1 ? "doesn't" : "don't") divide evenly into \(n == 1 ? "its" : "their") counts, so only the first bar line of each is placed."
        case "measure_range_gaps":
            systemImage = "music.note.list"
            title = "Measure numbers skip"
            detail = "\(Translation.count(n, "set")) \(n == 1 ? "starts" : "start") on a measure that doesn't follow on from the set before."
        case "user_page_map":
            systemImage = "flag"
            title = "Sets came from your page map"
            detail = "Set boundaries were taken from the page map you chose (\(Translation.count(n, "entry", plural: "entries")))."
        case "sets_inferred_from_motion":
            systemImage = "flag"
            title = "Sets were guessed from movement"
            detail = "The file didn't mark its sets, so Fieldwork placed \(Translation.count(n, "set")) where movement pauses. They may not match the designer's pages."
        case "sets_out_of_order":
            systemImage = "flag"
            title = "Some sets were reordered"
            detail = "Sets in the original didn't run in order. Fieldwork sorted them and removed duplicates."
        case "set_beyond_timeline":
            systemImage = "flag.slash"
            title = "Some sets were left out"
            detail = "\(Translation.count(n, "set")) \(n == 1 ? "starts" : "start") after the drill's last count, so \(n == 1 ? "it" : "they") couldn't be imported."
        case "no_sets":
            systemImage = "flag.slash"
            title = "No sets were found"
            detail = "The file doesn't mark where sets begin. Import again with a page map, or allow approximations to split the drill where movement pauses."
        case "first_set_not_at_zero":
            systemImage = "flag"
            title = "The first set starts late"
            detail = "The first set begins on count \(n ?? 0) instead of count 0."
        case "trailing_static_counts":
            systemImage = "flag.checkered"
            title = "Extra counts after the last set"
            detail = "\(Translation.count(n, "count")) \(n == 1 ? "comes" : "come") after the final set with nobody moving, so the show ends at the final set."
        case "movement_after_final_set":
            systemImage = "figure.walk"
            title = "Movement after the last set was cut"
            detail = "\(Translation.count(n, "performer")) \(n == 1 ? "moves" : "move") during the \(Translation.count(text.number(1), "count")) after the final set. That movement isn't part of any set, so it wasn't kept."
        case "curve_subsets_added":
            systemImage = "point.topleft.down.to.point.bottomright.curvepath"
            title = "Subsets were added inside curved moves"
            detail = "\(Translation.count(n, "subset")) \(n == 1 ? "was" : "were") added so every count matches the original. \(n == 1 ? "It isn't one" : "They aren't") of the designer's pages."
        case "curves_as_paths":
            systemImage = "point.topleft.down.to.point.bottomright.curvepath"
            title = "Curved moves were kept"
            detail = "\(Translation.count(n, "performer move")) \(n == 1 ? "follows a curve" : "follow curves") and \(n == 1 ? "was" : "were") saved as paths that match every count."
        case "curves_flattened":
            systemImage = "line.diagonal"
            title = "Some curved moves became straight"
            detail = "\(Translation.count(n, "performer move")) inside curved moves had counts without a stored position, so \(n == 1 ? "it was" : "they were") made straight."
        case "duplicate_performer_id":
            systemImage = "person.2"
            title = "A performer was listed twice"
            detail = "The original roster lists the same performer twice. Fieldwork kept the first entry."
        case "labels_made_unique":
            systemImage = "tag"
            title = "Some labels were renamed"
            detail = "\(Translation.count(n, "performer")) shared a label with someone else, so a suffix was added to tell them apart."
        case "orphan_samples":
            systemImage = "person.crop.circle.badge.questionmark"
            title = "Some positions had no performer"
            detail = "\(Translation.count(n, "stored position")) belonged to performers who aren't in the roster, so \(n == 1 ? "it was" : "they were") skipped."
        case "missing_samples":
            systemImage = "questionmark.circle"
            title = "Some positions were missing"
            detail = "\(Translation.count(n, "performer position")) \(n == 1 ? "is" : "are") missing from the original file."
        case "non_finite_positions":
            systemImage = "exclamationmark.circle"
            title = "Some positions were unreadable"
            detail = "\(Translation.count(n, "coordinate")) \(n == 1 ? "was" : "were") damaged in the file and left out."
        case "alternate_markers":
            systemImage = "circle.dashed"
            title = "Some dots use another marker style"
            detail = "\(Translation.count(n, "position")) \(n == 1 ? "is" : "are") drawn with a different marker in the original. Positions are unaffected."
        case "timeline_length_mismatch":
            systemImage = "clock.badge.exclamationmark"
            title = "The drill's length was unclear"
            let kept = text.capture(#"using the first ([0-9]+) counts"#) ?? "the shared"
            detail = "Parts of the file disagree about how long the drill is. Fieldwork used the first \(kept) counts."
        case "count_times_not_increasing":
            systemImage = "clock.badge.exclamationmark"
            title = "Count times were out of order"
            detail = "Some counts in the original are stamped out of order, so timing around them may be off."
        case "missing_grid":
            systemImage = "ruler"
            title = "The step size was assumed"
            detail = "The file has no step grid, so Fieldwork assumed 8 steps per 5 yards."
        case "missing_border":
            systemImage = "rectangle.dashed"
            title = "The field size was assumed"
            detail = "The file has no field border, so Fieldwork assumed a standard football field."
        case "unknown_unit_code":
            systemImage = "ruler"
            title = "The units were assumed"
            detail = "The file uses a unit Fieldwork doesn't recognize, so it assumed yards. If spacing looks wrong, import again and set the steps per unit."
        case "invalid_transform":
            systemImage = "arrow.up.and.down.and.arrow.left.and.right"
            title = "The field orientation couldn't be applied"
            detail = "Positions may be flipped or shifted. Check the field, and import again with different flip settings if needed."
        case "line_annotations_not_exported":
            systemImage = "scribble"
            title = "Drawn lines weren't imported"
            detail = "\(Translation.count(n, "line")) drawn on the field \(n == 1 ? "has" : "have") no equivalent in Fieldwork yet."
        case "notes_moved_to_next_set":
            systemImage = "note.text"
            title = "Some notes moved to the next set"
            detail = "\(Translation.count(n, "text note")) sat between sets, so \(n == 1 ? "it was" : "they were") attached to the set that follows."
        case "props_in_extension":
            systemImage = "shippingbox"
            title = "Props were set aside"
            detail = "\(Translation.count(n, "prop")) \(n == 1 ? "isn't a performer" : "aren't performers"). \(n == 1 ? "It's" : "They're") kept in the file for when Fieldwork supports props."
        default:
            systemImage = "info.circle"
            title = "Note from the converter"
            detail = Translation.sentence(diagnostic.message)
        }
    }
}

/// Pulls numbers and phrases out of a converter message.
private struct Translation {
    let message: String

    init(_ message: String) { self.message = message }

    /// The nth plain number in the message.
    func number(_ index: Int) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\w.])\d+(?![\w.])"#) else { return nil }
        let matches = regex.matches(in: message, range: NSRange(message.startIndex..., in: message))
        guard index < matches.count, let range = Range(matches[index].range, in: message) else { return nil }
        return Int(message[range])
    }

    /// The first capture group of `pattern`.
    func capture(_ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: message) else { return nil }
        return String(message[range])
    }

    /// "3 sets", "1 set", "some sets" when the count is unknown.
    static func count(_ n: Int?, _ singular: String, plural: String? = nil) -> String {
        guard let n else { return "Some \(plural ?? singular + "s")" }
        return "\(n.formatted()) \(n == 1 ? singular : plural ?? singular + "s")"
    }

    /// "0.53 seconds".
    static func seconds(_ value: Double) -> String {
        let text = value.formatted(.number.precision(.fractionLength(0...2)))
        return "\(text) second\(value == 1 ? "" : "s")"
    }

    /// "254-259, 260-262" → "254–259 and 260–262".
    static func ranges(_ list: String) -> String {
        let items = list.replacingOccurrences(of: "-", with: "–").components(separatedBy: ", ")
        guard items.count > 1 else { return items.first ?? list }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// The converter's message as a sentence, without command-line advice.
    static func sentence(_ message: String) -> String {
        let trimmed = message.components(separatedBy: ". Check with --").first ?? message
        guard let first = trimmed.first else { return message }
        let text = first.uppercased() + trimmed.dropFirst()
        return text.hasSuffix(".") ? text : text + "."
    }
}
