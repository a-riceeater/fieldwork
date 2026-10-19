import SwiftUI
import DrillTiming
import DrillCore

/// Context-sensitive inspector: set/timing settings when nothing is selected;
/// exact coordinates for one performer; group operations for several. Field
/// settings live in the Project Settings sheet.
struct InspectorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.l) {
                switch model.selection.count {
                case 0:
                    if let note = model.focusedNote {
                        NoteInspector(model: model, note: note).id(note.id)
                    }
                    SetInspector(model: model)
                    TimingInspector(model: model)
                    IssuesInspector(model: model)
                case 1:
                    PerformerInspector(model: model, id: model.selection.first!)
                    FormInspector(model: model)
                default:
                    // A whole form selected is shape editing, so the form comes first.
                    if model.show.forms(on: model.currentSetID).contains(where: { Set($0.members) == model.selection }) {
                        FormInspector(model: model)
                        GroupInspector(model: model)
                    } else {
                        GroupInspector(model: model)
                        FormInspector(model: model)
                    }
                }
            }
            .padding(Tokens.Space.m)
        }
        .background(VisualEffectBackground(material: .sidebar))
    }
}

struct InspectorSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.fwSecondary)
                .padding(.leading, Tokens.Space.xs)
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Tokens.Space.m)
            .fwCard()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A text field that commits a locale-independent number on Return or focus loss.
struct NumberField: View {
    var label: String
    var value: Double
    var places = 3
    var commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $text)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 96)
                .focused($focused)
                .onSubmit(apply)
                .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
                .onAppear { text = TimeFormat.decimal(value, places: places) }
                .onChange(of: value) { _, newValue in if !focused { text = TimeFormat.decimal(newValue, places: places) } }
                .labelsHidden()
                .accessibilityLabel(label)
        }
    }

    private func apply() {
        guard let parsed = Double(text.trimmingCharacters(in: .whitespaces)), parsed.isFinite else {
            text = TimeFormat.decimal(value, places: places)
            return
        }
        if abs(parsed - value) > pow(10, Double(-places)) / 2 { commit(parsed) }
    }
}

struct SetInspector: View {
    @ObservedObject var model: EditorModel
    @State private var label = ""
    @State private var mark = ""
    @State private var marker = ""
    @FocusState private var focusedMarker: MarkerField?

    private enum MarkerField { case mark, measures }

    var body: some View {
        InspectorSection(title: "Set") {
            if let set = model.currentSet {
                LabeledContent("Label") {
                    TextField("Label", text: $label).frame(width: 96).onSubmit { model.renameCurrentSet(label) }
                }
                .onAppear { label = set.label }
                .onChange(of: set.label) { _, newValue in label = newValue }
                LabeledContent("Rehearsal mark") {
                    TextField("None", text: $mark)
                        .frame(width: 96)
                        .focused($focusedMarker, equals: .mark)
                        .onSubmit(saveMarkers)
                        .help("Rehearsal letter that starts at this set, such as A, B or CC")
                }
                LabeledContent("Measures") {
                    TextField(measurePlaceholder(set), text: $marker)
                        .frame(width: 96)
                        .focused($focusedMarker, equals: .measures)
                        .onSubmit(saveMarkers)
                        .help(model.show.countingMode == .counts
                              ? "Measure numbers for this set, such as 222-223. Only a label; it never moves the set."
                              : "Leave empty to show the measure from the timeline, or type your own label")
                }
                .onAppear { mark = set.rehearsalMark; marker = set.measureMarker }
                .onChange(of: set) { _, newValue in mark = newValue.rehearsalMark; marker = newValue.measureMarker }
                .onChange(of: focusedMarker) { _, newValue in if newValue == nil { saveMarkers() } }
                if let count = model.show.cumulativeCount(of: set, map: model.map) {
                    Text("Arrives on count \(TimeFormat.decimal(count.doubleValue, places: count.isInteger ? 0 : 2))")
                        .font(.caption).monospacedDigit().foregroundStyle(Color.fwSecondary)
                }
                if model.show.previousSet(before: set.id) != nil {
                    let counts = (try? model.show.moveCounts(into: set.id, map: model.map)) ?? .zero
                    NumberField(label: "Move counts", value: counts.doubleValue, places: 0) { model.setMoveCounts(Int($0.rounded())) }
                    Text("Later sets shift so their moves keep their lengths.").font(.caption).foregroundStyle(Color.fwSecondary)
                    if counts.isInteger, counts.numerator > 1 {
                        SplitMoveControl(model: model, setID: set.id, total: Int(counts.numerator))
                    }
                } else {
                    Text("Preset · count 0").foregroundStyle(Color.fwSecondary)
                }
                let unresolved = model.show.performers.filter { model.show.formation(set.id)[$0.id] == .unresolved }.count
                if unresolved > 0 {
                    Label("\(unresolved) without a position", systemImage: "questionmark.circle")
                        .foregroundStyle(Color.fwWarning)
                    Button("Place All on the Field") { model.placeUnplaced() }
                        .disabled(!model.isEditable)
                        .help("Put everyone without a position into blocks by section")
                }
                Button { model.addNote() } label: { Label("Add Note", systemImage: "note.text.badge.plus") }
                    .disabled(!model.isEditable)
                    .help("Add a text box on the field at this set. Click it on the field to edit it here.")
            }
        }
    }

    private func measurePlaceholder(_ set: ArrivalSet) -> String {
        guard model.show.countingMode == .measures, let map = model.map, let position = try? map.musicalPosition(at: set.cursor) else {
            return "e.g. 222-223"
        }
        return position.label
    }

    private func saveMarkers() {
        model.setCurrentSetMarkers(rehearsalMark: mark.trimmingCharacters(in: .whitespaces), measureMarker: marker.trimmingCharacters(in: .whitespaces))
    }
}

/// Edits the focused field note. The box itself is only dragged on the field;
/// its text is typed here and commits as one edit when focus leaves.
struct NoteInspector: View {
    @ObservedObject var model: EditorModel
    var note: FieldNote
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        InspectorSection(title: "Note") {
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 96)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                .focused($focused)
                .disabled(!model.isEditable)
                .accessibilityLabel("Note text")
            if text.count > FieldNote.maxLength {
                Label("Notes are limited to \(FieldNote.maxLength) characters.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Color.fwWarning)
            }
            Text("Shown on the field at this set and hidden during playback. Drag the box on the field to move it.")
                .font(.caption).foregroundStyle(Color.fwSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Done") {
                    save()
                    model.focusedNoteID = nil
                }
                Spacer()
                Button("Delete Note", role: .destructive) { model.deleteNote(note.id) }
                    .disabled(!model.isEditable)
            }
        }
        .onAppear {
            text = note.text
            if note.text.isEmpty, model.isEditable { DispatchQueue.main.async { focused = true } }
        }
        .onChange(of: note.text) { _, newValue in if !focused { text = newValue } }
        .onChange(of: text) { _, newValue in
            if focused { model.noteDraft = FieldNote(id: note.id, setID: note.setID, position: note.position, text: newValue) }
        }
        .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
        .onDisappear(perform: save)
    }

    private func save() {
        guard model.show.fieldNote(note.id) != nil else { return }
        model.editNote(note.id, text: text)
    }
}

/// Splits the move into a set with a subset at a chosen count (1 → 2 becomes 1 → 1A → 2).
struct SplitMoveControl: View {
    @ObservedObject var model: EditorModel
    var setID: SetID
    var total: Int
    @State private var count = 0

    var body: some View {
        HStack(spacing: Tokens.Space.s) {
            Stepper(value: $count, in: 1...(total - 1)) {
                Text("Split at count \(count)").monospacedDigit()
            }
            Spacer()
            Menu("Split") {
                Button("At Count \(count)") { model.splitMove(into: setID, atCount: count) }
                Divider()
                preset("Quarter", total / 4)
                preset("Halfway", total / 2)
                preset("Three Quarters", total * 3 / 4)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add a subset partway through this move. Its positions come from the move itself.")
        }
        .disabled(model.readOnlyReason != nil || model.isPlaying)
        .onAppear { count = max(total / 2, 1) }
        .onChange(of: total) { _, newValue in count = max(newValue / 2, 1) }
        .onChange(of: setID) { _, _ in count = max(total / 2, 1) }
    }

    private func preset(_ name: String, _ count: Int) -> some View {
        let at = min(max(count, 1), total - 1)
        return Button("\(name) · Count \(at)") { model.splitMove(into: setID, atCount: at) }
    }
}

struct TimingInspector: View {
    @ObservedObject var model: EditorModel
    @State private var numerator = 4
    @State private var denominator = 4
    @State private var bpm = 120.0
    @State private var measures = 32
    @State private var pulse = 0
    @State private var tempoFrom = 1
    @State private var tempoTo = 1
    @State private var tempoBPM = 120.0

    var body: some View {
        let timing = model.movement.timing
        InspectorSection(title: model.show.countingMode == .counts ? "Tempo" : "Music and counts") {
            if model.show.countingMode == .counts, let map = model.map {
                Text("\(TimeFormat.decimal(map.totalPulses.doubleValue, places: 0)) counts · \(timing.anchors.count) audio pin\(timing.anchors.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(Color.fwSecondary)
            } else if let first = timing.measures.first {
                Text("\(timing.measures.count) measures · \(first.meter.description) · \(timing.anchors.count) audio pin\(timing.anchors.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(Color.fwSecondary)
            }
            if model.show.countingMode == .counts {
                NumberField(label: "Tempo (BPM)", value: tempoBPM, places: 1) { tempoBPM = $0 }
                if model.setsInMovement.count == 1 && timing.anchors.isEmpty, let first = timing.measures.first {
                    Button("Set Tempo") {
                        model.configureTimeline(numerator: first.meter.numerator, denominator: first.meter.denominator, bpm: tempoBPM,
                                                pulse: first.pulseUnit, measures: timing.measures.count)
                    }
                } else {
                    Button("Set Tempo for This Move") { model.setTempoForCurrentMove(bpm: tempoBPM) }
                        .disabled(model.show.previousSet(before: model.currentSetID) == nil)
                }
                Text("Counts only: sets are pages of counts and meters are ignored. With music, pin each page with Align Set Here instead of changing tempo.")
                    .font(.caption).foregroundStyle(Color.fwSecondary)
            } else if model.setsInMovement.count == 1 && timing.anchors.isEmpty {
                Stepper("Meter \(numerator)/\(denominator)", value: $numerator, in: 1...15)
                Picker("Note value", selection: $denominator) {
                    ForEach([2, 4, 8, 16], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("March count", selection: $pulse) {
                    Text("Notated beat").tag(0)
                    Text("Dotted quarter").tag(1)
                    Text("Eighth").tag(2)
                }
                NumberField(label: "Tempo (BPM)", value: bpm, places: 1) { bpm = $0 }
                Stepper("\(measures) measures", value: $measures, in: 1...999)
                Button("Set Meter and Tempo") {
                    let unit: Rational? = pulse == 1 ? NoteValue.dottedQuarter : (pulse == 2 ? NoteValue.eighth : nil)
                    model.configureTimeline(numerator: numerator, denominator: denominator, bpm: bpm, pulse: unit, measures: measures)
                }
                Text("Meter and count pulse are set before sets or pins exist.").font(.caption).foregroundStyle(Color.fwSecondary)
            } else {
                Stepper("From m\(tempoFrom)", value: $tempoFrom, in: 0...max(1, timing.measures.count))
                Stepper("To m\(tempoTo)", value: $tempoTo, in: tempoFrom...max(tempoFrom, timing.measures.count))
                NumberField(label: "Tempo (BPM)", value: tempoBPM, places: 1) { tempoBPM = $0 }
                Button("Change Tempo") { model.setTempo(firstMeasure: tempoFrom, lastMeasure: tempoTo, bpm: tempoBPM) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("When tempo changes").font(.caption).foregroundStyle(Color.fwSecondary)
                Picker("When tempo changes", selection: Binding(get: { timing.fitMode }, set: { model.setFitMode($0) })) {
                    Text("Preserve audio pins").tag(FitMode.preserveAudioPins)
                    Text("Preserve notated tempo").tag(FitMode.preserveNotatedTempo)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            if let first = timing.measures.first {
                numerator = first.meter.numerator
                denominator = first.meter.denominator
                measures = timing.measures.count
                if let beat = timing.events.first(where: { $0.kind == .beat }), let tempo = timing.baselineTempo(of: beat) {
                    bpm = tempo.rounded()
                    tempoBPM = bpm
                }
            }
        }
    }
}

struct IssuesInspector: View {
    @ObservedObject var model: EditorModel
    @AppStorage("FieldworkWarningsExpanded") private var expanded = false

    var body: some View {
        let issues = model.analysisIssues
        DisclosureGroup(isExpanded: $expanded) {
            if issues.isEmpty {
                Text("No stride, bounds or missing-position warnings.").font(.caption).foregroundStyle(Color.fwSecondary)
            }
            ForEach(issues.prefix(40)) { issue in
                Button {
                    model.selectSet(issue.setID)
                    model.selection = Set(issue.performers)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(issue.kind.title, systemImage: icon(issue.kind)).font(.system(size: 11, weight: .semibold))
                        Text(issue.message).font(.system(size: 11)).foregroundStyle(Color.fwSecondary).multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.fwWarning)
                .help("Jump to this set and select the performers")
            }
            Text("Warnings are design aids, not safety guarantees.").font(.caption2).foregroundStyle(Color.fwSecondary)
        } label: {
            Label("Warnings (\(issues.count))", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.fwSecondary)
        }
        .padding(Tokens.Space.m)
        .fwCard()
        .accessibilityIdentifier("inspector.warnings")
    }

    func icon(_ kind: DrillIssue.Kind) -> String {
        switch kind {
        case .unresolvedPosition: return "questionmark.circle"
        case .outOfBounds: return "rectangle.dashed"
        case .largeStride: return "figure.walk.motion"
        case .discontinuity: return "bolt.horizontal"
        case .closePass: return "arrow.left.and.right.circle"
        }
    }
}

struct PerformerInspector: View {
    @ObservedObject var model: EditorModel
    var id: PerformerID

    var body: some View {
        if let performer = model.show.performer(id) {
            let placement = model.show.formation(model.currentSetID)[id]
            let describer = CoordinateDescriber(field: model.show.field)
            let section = model.show.section(performer.sectionID)
            InspectorSection(title: "Performer \(performer.label)") {
                Text(section?.name ?? "").foregroundStyle(Color.fwSecondary)
                SymbolRow(model: model, ids: [id])
                if let p = placement.position {
                    NumberField(label: "x (m)", value: p.x) { model.setCoordinate(id, x: $0, y: p.y) }
                    NumberField(label: "y (m)", value: p.y) { model.setCoordinate(id, x: p.x, y: $0) }
                    NumberField(label: "x (steps)", value: p.x / model.show.field.stepSize, places: 2) {
                        model.setCoordinate(id, x: $0 * model.show.field.stepSize, y: p.y)
                    }
                    NumberField(label: "y (steps)", value: p.y / model.show.field.stepSize, places: 2) {
                        model.setCoordinate(id, x: p.x, y: $0 * model.show.field.stepSize)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(describer.sideToSide(p.x))
                        Text(describer.frontToBack(p.y))
                    }
                    .font(.system(size: 12)).monospacedDigit()
                    Button("Clear Position") { model.setPlacementUnresolved([id]) }
                } else {
                    Label("No position at this set", systemImage: "questionmark.circle").foregroundStyle(Color.fwWarning)
                    Button("Place at Field Center") { model.setCoordinate(id, x: 0, y: 0) }
                }
            }
        }
    }
}

struct GroupInspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let formation = model.show.formation(model.currentSetID)
        let points = model.selection.compactMap { formation[$0].position?.point }
        InspectorSection(title: "\(model.selection.count) performers") {
            if !points.isEmpty {
                let bounds = Rect2(points: points)
                let step = model.show.field.stepSize
                Text("Bounds \(TimeFormat.decimal(bounds.width / step, places: 1)) × \(TimeFormat.decimal(bounds.height / step, places: 1)) steps")
                    .font(.system(size: 12)).monospacedDigit()
            }
            if points.count < model.selection.count {
                Label("\(model.selection.count - points.count) without a position", systemImage: "questionmark.circle").foregroundStyle(Color.fwWarning)
            }
            SymbolRow(model: model, ids: Array(model.selection))
            Text("Arrange").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.fwSecondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: Tokens.Space.xs) {
                ArrangeButtons(model: model)
            }
            .disabled(!model.isEditable)
            Text("Shapes are placed in label order where the selection is (or at midfield). To draw one yourself, choose Line or Arc in the toolbar and drag on the field.")
                .font(.caption).foregroundStyle(Color.fwSecondary)
        }
    }
}

/// Symbol choice for one or more performers: their section's symbol or their own.
struct SymbolRow: View {
    @ObservedObject var model: EditorModel
    var ids: [PerformerID]

    var body: some View {
        let performers = ids.compactMap(model.show.performer)
        let sections = Set(performers.map(\.sectionID))
        let choices = Set(performers.map(\.symbol))
        let section = sections.count == 1 ? sections.first.flatMap(model.show.section) : nil
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            Text("Symbol").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.fwSecondary)
            SymbolPicker(selection: choices.first ?? nil, colorIndex: section?.colorIndex ?? 0, allowsSection: true,
                         sectionSymbol: section?.symbol, showsSelection: choices.count == 1) { symbol in
                if choices != [symbol] { model.setSymbol(ids, symbol: symbol) }
            }
            // While everyone is drawn as circles a change would be invisible, so it is not offered.
            .disabled(!model.isEditable || model.circlesOnly)
            if model.circlesOnly {
                Text("Turn off View › Draw Everyone as Circles to change symbols.").font(.caption).foregroundStyle(Color.fwSecondary)
            }
        }
    }
}

struct FormInspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let forms = model.show.forms(on: model.currentSetID).filter { !model.selection.isDisjoint(with: $0.members) }
        if !forms.isEmpty {
            InspectorSection(title: "Form") {
                ForEach(forms) { form in
                    VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                        Text("\(form.geometry.kindName) · \(form.members.count) performers · \(TimeFormat.decimal(form.geometry.length / model.show.field.stepSize, places: 1)) steps long")
                            .font(.system(size: 12))
                        if case .arc(let s, let e, let bulge) = form.geometry {
                            NumberField(label: "Bulge (m)", value: bulge, places: 2) { model.commitHandle(form.id, geometry: .arc(start: s, end: e, bulge: $0)) }
                        }
                        HStack {
                            Button("Reverse Order") { model.reverseForm(form.id) }
                            Button("Detach") { model.detachForm(form.id) }
                                .help("Keep positions and edit dots independently")
                        }
                    }
                }
                Text("Drag a ring to reshape; spacing stays equal along the form. Drag the line or any performer to move the whole form. Double-click a performer to work on it alone; moving it on its own takes it out of the form.").font(.caption).foregroundStyle(Color.fwSecondary)
            }
        }
    }
}
