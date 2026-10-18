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

        init(name: String, prefix: String, count: Int) {
            self.name = name
            self.prefix = prefix
            self.count = count
        }

        /// A section from the instrument list, with its drill letter.
        init(preset: String, count: Int) {
            let instrument = InstrumentPreset.named(preset)
            self.init(name: instrument?.name ?? preset, prefix: instrument?.prefix ?? String(preset.prefix(1)), count: count)
        }
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

/// Resizable welcome window. The New Show flow replaces the start page inside
/// the same window, so both grow with the window.
struct WelcomeView: View {
    static let beginNewShow = Notification.Name("FieldworkBeginNewShow")

    var create: (NewShowRequest) -> Void
    var open: () -> Void
    var sample: () -> Void
    var openRecent: (URL) -> Void
    @State private var creating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if creating {
                NewShowFlow(create: create, cancel: { show(creating: false) })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                home
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 760, idealWidth: 900, maxWidth: .infinity, minHeight: 540, idealHeight: 620, maxHeight: .infinity)
        .background(VisualEffectBackground(material: .underWindowBackground).ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: WelcomeView.beginNewShow)) { _ in show(creating: true) }
    }

    private func show(creating value: Bool) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) { creating = value }
    }

    private var home: some View {
        HStack(spacing: 0) {
            VStack(spacing: Tokens.Space.xl) {
                Spacer(minLength: Tokens.Space.xl)
                VStack(spacing: Tokens.Space.m) {
                    FieldThumbnail(field: .make(.highSchoolFootball))
                        .frame(width: 200)
                        .padding(.bottom, Tokens.Space.s)
                    Text("Fieldwork")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                    Text("Precise drill, aligned to your music.")
                        .font(.title3)
                        .foregroundStyle(Color.fwSecondary)
                }
                VStack(spacing: Tokens.Space.s) {
                    ActionTile(title: "Create Show", subtitle: "Choose a field, add your ensemble and music",
                               systemImage: "plus", prominent: true) { show(creating: true) }
                        .keyboardShortcut(.defaultAction)
                    ActionTile(title: "Open Show…", subtitle: "Continue working on a .fieldwork file",
                               systemImage: "folder", action: open)
                    ActionTile(title: "Try the Sample", subtitle: "A 90-second show with music and four sets",
                               systemImage: "play.fill", action: sample)
                }
                .frame(maxWidth: 400)
                .glassGroup()
                Spacer(minLength: Tokens.Space.l)
                Text("No account needed. Shows are files you own.")
                    .font(.caption)
                    .foregroundStyle(Color.fwSecondary)
            }
            .padding(Tokens.Space.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            recents
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Shows")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.fwSecondary)
                .padding(.horizontal, Tokens.Space.l)
                .padding(.top, 44)
                .padding(.bottom, Tokens.Space.s)
            let urls = NSDocumentController.shared.recentDocumentURLs
            if urls.isEmpty {
                ContentUnavailableView("No Recent Shows", systemImage: "clock", description: Text("Shows you open appear here."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(urls, id: \.self) { url in
                            RecentShowRow(url: url) { openRecent(url) }
                        }
                    }
                    .padding(.horizontal, Tokens.Space.s)
                    .padding(.bottom, Tokens.Space.l)
                }
            }
        }
    }
}

private struct RecentShowRow: View {
    var url: URL
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.s) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.fwSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tokens.Space.s)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.path)
    }
}

/// Four short steps: field, ensemble, music (optional), first sets. Every
/// step scrolls, so long rosters stay usable at any window size.
struct NewShowFlow: View {
    var create: (NewShowRequest) -> Void
    var cancel: () -> Void
    @State private var request = NewShowRequest(sections: [
        .init(preset: "Trumpet", count: 8),
        .init(preset: "Mellophone", count: 6),
        .init(preset: "Baritone", count: 4),
        .init(preset: "Tuba", count: 4),
        .init(preset: "Snare Drum", count: 4),
        .init(preset: "Color Guard", count: 8),
    ])
    @State private var step = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let titles = ["Field", "Ensemble", "Music", "First Sets"]

    private var performerTotal: Int { request.sections.reduce(0) { $0 + max(0, $1.count) } }

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(titles: titles, current: step) { go(to: $0) }
                .padding(.top, 34)
                .padding(.bottom, Tokens.Space.m)
                .frame(maxWidth: .infinity)
            Divider()
            Group {
                switch step {
                case 0: fieldStep
                case 1: ensembleStep
                case 2: musicStep
                default: setsStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(step)
            .transition(.opacity)
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: Tokens.Space.s) {
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
                .fwSecondaryButton()
            Spacer()
            if step > 0 {
                Button("Back") { go(to: step - 1) }
                    .fwSecondaryButton()
            }
            Button("Skip for Now") { skipCurrent() }
                .fwSecondaryButton()
                .help("Continue with defaults; you can change everything later")
            Button(step == 3 ? "Create Show" : "Continue") {
                if step == 3 { create(request) } else { go(to: step + 1) }
            }
            .keyboardShortcut(.defaultAction)
            .fwPrimaryButton()
        }
        .controlSize(.large)
        .padding(.horizontal, Tokens.Space.xl)
        .padding(.vertical, Tokens.Space.m)
    }

    private func go(to index: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { step = index }
    }

    private func skipCurrent() {
        switch step {
        case 1: request.sections = []
        case 2: request.audioURL = nil
        case 3: request.setCount = 1
        default: break
        }
        if step == 3 { create(request) } else { go(to: step + 1) }
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle).foregroundStyle(Color.fwSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A step page: header over grouped-form content, centered at a readable width.
    private func page<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title, subtitle)
                .padding(.horizontal, Tokens.Space.xl + Tokens.Space.xs)
                .padding(.top, Tokens.Space.xl)
            content()
        }
        .frame(maxWidth: 880)
        .frame(maxWidth: .infinity)
    }

    // MARK: Steps

    private var fieldStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.l) {
                header("Name your show", "Then choose the surface you'll march on.")
                TextField("Show title", text: $request.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .fwCard(cornerRadius: 10)
                    .accessibilityLabel("Show title")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Tokens.Space.m)], spacing: Tokens.Space.m) {
                    ForEach(Field.Preset.allCases.filter { $0 != .custom }, id: \.self) { preset in
                        FieldPresetCard(field: .make(preset), title: preset.displayName, isSelected: request.field == preset) {
                            request.field = preset
                        }
                    }
                }
                Text("Custom dimensions can be set later in File › Project Settings….")
                    .font(.caption)
                    .foregroundStyle(Color.fwSecondary)
            }
            .padding(Tokens.Space.xl)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
        }
    }

    private var ensembleStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: Tokens.Space.l) {
                header("Who's marching?", "Add a section for each instrument. Labels like T1 and T2 stay with each performer for the whole show.")
                addSectionMenu
            }
            .padding(.horizontal, Tokens.Space.xl + Tokens.Space.xs)
            .padding(.top, Tokens.Space.xl)
            if request.sections.isEmpty {
                ContentUnavailableView("No Sections Yet", systemImage: "person.3",
                                       description: Text("Add a section, or skip and build the roster in the editor."))
                    .frame(maxHeight: .infinity)
            } else {
                Form {
                    SwiftUI.Section {
                        ForEach($request.sections) { $section in
                            sectionRow($section)
                        }
                    } footer: {
                        Text("\(performerTotal) performers in \(request.sections.count) section\(request.sections.count == 1 ? "" : "s"). Letters can be changed any time from the roster.")
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: 880)
        .frame(maxWidth: .infinity)
    }

    private func sectionRow(_ section: Binding<NewShowRequest.SectionDraft>) -> some View {
        let index = request.sections.firstIndex { $0.id == section.wrappedValue.id } ?? 0
        return HStack(spacing: Tokens.Space.m) {
            Circle()
                .fill(Color(nsColor: Tokens.sectionColor(index)))
                .frame(width: 10, height: 10)
            InstrumentPicker(name: section.name, prefix: section.prefix)
                .labelsHidden()
                .frame(minWidth: 220, maxWidth: 360, alignment: .leading)
            Spacer(minLength: Tokens.Space.s)
            TextField("Letter", text: section.prefix)
                .multilineTextAlignment(.center)
                .frame(width: 52)
                .help("Label letter, for example T for T1, T2…")
                .accessibilityLabel("Label letter for \(section.wrappedValue.name)")
            HStack(spacing: 4) {
                TextField("Count", value: section.count, format: .number)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 44)
                    .accessibilityLabel("Performers in \(section.wrappedValue.name)")
                Stepper("Performers", value: section.count, in: 0...400)
                    .labelsHidden()
            }
            Button {
                let id = section.wrappedValue.id
                withAnimation(reduceMotion ? nil : .default) { request.sections.removeAll { $0.id == id } }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.fwSecondary)
            .help("Remove this section")
            .accessibilityLabel("Remove \(section.wrappedValue.name)")
        }
    }

    private var addSectionMenu: some View {
        Menu {
            ForEach(InstrumentPreset.Family.allCases, id: \.self) { family in
                SwiftUI.Section(family.displayName) {
                    ForEach(InstrumentPreset.family(family)) { preset in
                        Button("\(preset.name) (\(preset.prefix))") { addSection(name: preset.name, prefix: preset.prefix) }
                    }
                }
            }
            Divider()
            Button("Other…") { addSection(name: "", prefix: "") }
        } label: {
            Label("Add Section", systemImage: "plus")
        }
        .fixedSize()
    }

    private func addSection(name: String, prefix: String) {
        withAnimation(reduceMotion ? nil : .default) {
            request.sections.append(.init(name: name, prefix: prefix, count: 4))
        }
    }

    private var musicStep: some View {
        page("Music and counts", "Set the meter and tempo. Music is optional and can be added later.") {
            Form {
                SwiftUI.Section("Meter and tempo") {
                    LabeledContent("Meter") {
                        HStack(spacing: Tokens.Space.s) {
                            Stepper(value: $request.numerator, in: 1...15) {
                                Text("\(request.numerator)").monospacedDigit()
                            }
                            Text("/").foregroundStyle(Color.fwSecondary)
                            Picker("Note value", selection: $request.denominator) {
                                ForEach([2, 4, 8], id: \.self) { Text("\($0)").tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 64)
                        }
                    }
                    LabeledContent("Tempo") {
                        HStack(spacing: Tokens.Space.xs) {
                            TextField("Tempo", value: $request.bpm, format: .number.locale(Locale(identifier: "en_US_POSIX")))
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(width: 64)
                                .labelsHidden()
                            Text("BPM").foregroundStyle(Color.fwSecondary)
                        }
                    }
                    LabeledContent("Length") {
                        Stepper(value: $request.measures, in: 1...999) {
                            Text("\(request.measures) measures").monospacedDigit()
                        }
                    }
                }
                SwiftUI.Section {
                    HStack(spacing: Tokens.Space.m) {
                        Image(systemName: request.audioURL == nil ? "waveform.badge.plus" : "waveform")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.fwAccent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(request.audioURL?.lastPathComponent ?? "No music yet")
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(request.audioURL == nil ? "Counts only. Add music any time." : "Copied into the show when it's created.")
                                .font(.caption)
                                .foregroundStyle(Color.fwSecondary)
                        }
                        Spacer()
                        if request.audioURL != nil {
                            Button("Remove") { request.audioURL = nil }
                        }
                        Button(request.audioURL == nil ? "Choose WAV or MP3…" : "Replace…") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.wav, .mp3]
                            if panel.runModal() == .OK { request.audioURL = panel.url }
                        }
                    }
                } header: {
                    Text("Music")
                } footer: {
                    Text("You'll pin the first downbeat to the music in the editor.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private var setsStep: some View {
        page("First sets", "Start with a few sets to shape your opening.") {
            Form {
                SwiftUI.Section {
                    LabeledContent("Sets") {
                        Stepper(value: $request.setCount, in: 1...40) {
                            Text("\(request.setCount), including the opening set").monospacedDigit()
                        }
                    }
                    LabeledContent("Counts per move") {
                        Stepper(value: $request.countsPerSet, in: 1...64) {
                            Text("\(request.countsPerSet)").monospacedDigit()
                        }
                    }
                } footer: {
                    Text("Each new set starts as a copy of the one before it, so you can reshape from there.")
                }
                SwiftUI.Section("Summary") {
                    LabeledContent("Show", value: request.title.isEmpty ? "Untitled Show" : request.title)
                    LabeledContent("Field", value: Field.make(request.field).name)
                    LabeledContent("Performers", value: "\(performerTotal)")
                    LabeledContent("Total counts", value: "\(max(0, request.setCount - 1) * request.countsPerSet)")
                    LabeledContent("Music", value: request.audioURL?.lastPathComponent ?? "Counts only")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}
