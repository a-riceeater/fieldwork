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
                    SetInspector(model: model)
                    TimingInspector(model: model)
                    IssuesInspector(model: model)
                case 1:
                    PerformerInspector(model: model, id: model.selection.first!)
                    FormInspector(model: model)
                default:
                    GroupInspector(model: model)
                    FormInspector(model: model)
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

    var body: some View {
        InspectorSection(title: "Set") {
            if let set = model.currentSet {
                LabeledContent("Label") {
                    TextField("Label", text: $label).frame(width: 96).onSubmit { model.renameCurrentSet(label) }
                }
                .onAppear { label = set.label }
                .onChange(of: set.label) { _, newValue in label = newValue }
                if model.show.previousSet(before: set.id) != nil {
                    let counts = (try? model.show.moveCounts(into: set.id)) ?? .zero
                    NumberField(label: "Move counts", value: counts.doubleValue, places: 0) { model.setMoveCounts(Int($0.rounded())) }
                    Text("Later sets shift so their moves keep their lengths.").font(.caption).foregroundStyle(Color.fwSecondary)
                } else {
                    Text("Preset · count 0").foregroundStyle(Color.fwSecondary)
                }
                let unresolved = model.show.performers.filter { model.show.formation(set.id)[$0.id] == .unresolved }.count
                if unresolved > 0 {
                    Label("\(unresolved) without a position", systemImage: "questionmark.circle")
                        .foregroundStyle(Color.fwWarning)
                }
            }
        }
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
        InspectorSection(title: "Music and counts") {
            if let first = timing.measures.first {
                Text("\(timing.measures.count) measures · \(first.meter.description) · \(timing.anchors.count) audio pin\(timing.anchors.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(Color.fwSecondary)
            }
            if model.setsInMovement.count == 1 && timing.anchors.isEmpty {
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
            Picker("When tempo changes", selection: Binding(get: { timing.fitMode }, set: { model.setFitMode($0) })) {
                Text("Preserve audio pins").tag(FitMode.preserveAudioPins)
                Text("Preserve notated tempo").tag(FitMode.preserveNotatedTempo)
            }
            .pickerStyle(.radioGroup)
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

    var body: some View {
        let issues = model.analysisIssues
        InspectorSection(title: "Warnings (\(issues.count))") {
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
        }
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
            InspectorSection(title: "Performer \(performer.label)") {
                Text(model.show.section(performer.sectionID)?.name ?? "").foregroundStyle(Color.fwSecondary)
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
            Text("Choose Line or Arc in the toolbar, then drag on the field to place the selection in order.")
                .font(.caption).foregroundStyle(Color.fwSecondary)
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
                Text("Drag the white handles to reshape; spacing stays equal along the form.").font(.caption).foregroundStyle(Color.fwSecondary)
            }
        }
    }
}
