import SwiftUI
import UniformTypeIdentifiers
import DrillTiming
import DrillCore

/// Everything chosen in the New Show flow. "Skip for now" at any step still
/// yields a valid, editable show.
struct NewShowRequest {
    struct SectionDraft: Identifiable, Hashable {
        let id = UUID()
        var name: String
        var prefix: String
        var count: Int
    }

    var title = "Untitled Show"
    var field: Field.Preset = .highSchoolFootball
    var sections: [SectionDraft] = []
    var numerator = 4
    var denominator = 4
    var bpm = 120.0
    var measures = 32
    var audioURL: URL?
    var setCount = 1
    var countsPerSet = 16

    /// Builds the show through the same commands the editor uses.
    func build() throws -> Show {
        let session = try DocumentSession(show: try Show.makeNew(title: title.isEmpty ? "Untitled Show" : title, field: .make(field)))
        try session.perform(try session.show.makeConfigureTimeline(movementID: session.show.movements[0].id, meter: Meter(numerator, denominator),
                                                                   bpm: bpm, measures: measures))
        let requests = sections.filter { $0.count > 0 && !$0.name.isEmpty }.enumerated().map { index, draft in
            RosterSectionRequest(name: draft.name, prefix: draft.prefix.isEmpty ? String(draft.name.prefix(1)) : draft.prefix, count: draft.count,
                                 symbol: PerformerSymbol.allCases[index % PerformerSymbol.allCases.count], colorIndex: index)
        }
        if !requests.isEmpty { try session.perform(try session.show.makeRoster(requests)) }
        var last = session.show.sets[0].id
        for _ in 1..<max(1, setCount) {
            let id = SetID()
            try session.perform(try session.show.makeCreateSet(after: last, counts: countsPerSet, newSetID: id))
            last = id
        }
        return session.show
    }
}

struct WelcomeView: View {
    static let beginNewShow = Notification.Name("FieldworkBeginNewShow")

    var create: (NewShowRequest) -> Void
    var open: () -> Void
    var sample: () -> Void
    var openRecent: (URL) -> Void
    @State private var showingNewShow = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Tokens.Space.l) {
                Spacer()
                Text("Fieldwork")
                    .font(.system(size: 34, weight: .bold))
                Text("Precise drill, aligned to your music.")
                    .font(.title3)
                    .foregroundStyle(Color.fwSecondary)
                VStack(alignment: .leading, spacing: Tokens.Space.s) {
                    Button { showingNewShow = true } label: { Label("Create Show", systemImage: "plus.square") .frame(maxWidth: .infinity, alignment: .leading) }
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    Button(action: open) { Label("Open Show…", systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading) }
                        .controlSize(.large)
                    Button(action: sample) { Label("Try a 90-second Sample", systemImage: "play.square").frame(maxWidth: .infinity, alignment: .leading) }
                        .controlSize(.large)
                }
                .frame(width: 280)
                Text("No account needed. Shows are files you own.")
                    .font(.caption)
                    .foregroundStyle(Color.fwSecondary)
                Spacer()
            }
            .padding(Tokens.Space.xxl)
            Divider()
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                Text("Recent").font(.system(size: 13, weight: .semibold))
                let recents = NSDocumentController.shared.recentDocumentURLs
                if recents.isEmpty {
                    Text("Shows you open appear here.").foregroundStyle(Color.fwSecondary)
                }
                ForEach(recents, id: \.self) { url in
                    Button { openRecent(url) } label: {
                        VStack(alignment: .leading) {
                            Text(url.deletingPathExtension().lastPathComponent)
                            Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(Color.fwSecondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(Tokens.Space.xl)
            .frame(width: 280)
            .background(Color.fwSurface)
        }
        .frame(width: 720, height: 440)
        .background(Color.fwWindow)
        .sheet(isPresented: $showingNewShow) {
            NewShowFlow(create: { request in
                showingNewShow = false
                create(request)
            }, cancel: { showingNewShow = false })
        }
        .onReceive(NotificationCenter.default.publisher(for: WelcomeView.beginNewShow)) { _ in showingNewShow = true }
    }
}

/// Four short steps: field, ensemble, music (optional), first sets.
struct NewShowFlow: View {
    var create: (NewShowRequest) -> Void
    var cancel: () -> Void
    @State private var request = NewShowRequest(sections: [
        .init(name: "Trumpet", prefix: "T", count: 8),
        .init(name: "Mellophone", prefix: "M", count: 6),
        .init(name: "Low Brass", prefix: "B", count: 8),
        .init(name: "Battery", prefix: "D", count: 10),
    ])
    @State private var step = 0
    private let titles = ["Field", "Ensemble", "Music", "First sets"]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            HStack {
                ForEach(titles.indices, id: \.self) { i in
                    Text("\(i + 1). \(titles[i])")
                        .font(.system(size: 12, weight: i == step ? .semibold : .regular))
                        .foregroundStyle(i == step ? Color.fwAccent : Color.fwSecondary)
                    if i < titles.count - 1 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Color.fwSecondary) }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Step \(step + 1) of 4: \(titles[step])")

            Group {
                switch step {
                case 0: fieldStep
                case 1: ensembleStep
                case 2: musicStep
                default: setsStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button("Skip for now") { skipCurrent() }
                    .help("Continue with defaults; you can change everything later")
                Button(step == 3 ? "Create Show" : "Continue") {
                    if step == 3 { create(request) } else { step += 1 }
                }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.Space.xl)
        .frame(width: 560, height: 420)
    }

    private func skipCurrent() {
        switch step {
        case 1: request.sections = []
        case 2: request.audioURL = nil
        case 3: request.setCount = 1
        default: break
        }
        if step == 3 { create(request) } else { step += 1 }
    }

    private var fieldStep: some View {
        Form {
            TextField("Show title", text: $request.title)
            Picker("Field", selection: $request.field) {
                ForEach(Field.Preset.allCases.filter { $0 != .custom }, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text("Custom dimensions, hashes and step size can be edited in the inspector.").font(.caption).foregroundStyle(Color.fwSecondary)
        }
    }

    private var ensembleStep: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            ForEach($request.sections) { $section in
                HStack {
                    TextField("Section", text: $section.name).frame(width: 180)
                    TextField("Prefix", text: $section.prefix).frame(width: 60)
                    Stepper("\(section.count)", value: $section.count, in: 0...200).frame(width: 110)
                    Button { request.sections.removeAll { $0.id == section.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(section.name)")
                }
            }
            Button { request.sections.append(.init(name: "Section", prefix: "S", count: 4)) } label: { Label("Add Section", systemImage: "plus") }
                .buttonStyle(.borderless)
            Text("\(request.sections.reduce(0) { $0 + $1.count }) performers. Labels such as T1, T2 stay with each performer for the whole show.")
                .font(.caption).foregroundStyle(Color.fwSecondary)
        }
    }

    private var musicStep: some View {
        Form {
            HStack {
                Stepper("Meter \(request.numerator)/\(request.denominator)", value: $request.numerator, in: 1...15)
                Picker("", selection: $request.denominator) { ForEach([2, 4, 8], id: \.self) { Text("/\($0)").tag($0) } }.frame(width: 70)
            }
            TextField("Tempo (BPM)", value: $request.bpm, format: .number.locale(Locale(identifier: "en_US_POSIX")))
            Stepper("\(request.measures) measures", value: $request.measures, in: 1...999)
            HStack {
                Button("Choose WAV or MP3…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.wav, .mp3]
                    if panel.runModal() == .OK { request.audioURL = panel.url }
                }
                Text(request.audioURL?.lastPathComponent ?? "Counts only").foregroundStyle(Color.fwSecondary)
            }
            Text("Music is optional. You will align the first downbeat in the editor.").font(.caption).foregroundStyle(Color.fwSecondary)
        }
    }

    private var setsStep: some View {
        Form {
            Stepper("\(request.setCount) set\(request.setCount == 1 ? "" : "s") (including the preset)", value: $request.setCount, in: 1...40)
            Stepper("\(request.countsPerSet) counts per move", value: $request.countsPerSet, in: 1...64)
            Text("Each new set starts as a copy of the previous one so you can move the formation.").font(.caption).foregroundStyle(Color.fwSecondary)
        }
    }
}
