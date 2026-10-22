import SwiftUI
import DrillTiming
import DrillCore

/// Sets (with arrival counts) and roster sections.
struct NavigatorView: View {
    @ObservedObject var model: EditorModel
    @State private var tab = 0
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            CapsuleTabs(title: "Sidebar", selection: $tab, tabs: [CapsuleTab(value: 0, title: "Sets"), CapsuleTab(value: 1, title: "Roster")])
                .padding([.horizontal, .top], Tokens.Space.s)
                .padding(.bottom, Tokens.Space.xs)
            if tab == 0 { setsList } else { rosterList }
        }
        .fwPanel()
    }

    private var setsList: some View {
        let map = model.map
        let sets = model.setsInMovement
        return VStack(spacing: 0) {
            List(selection: Binding(get: { model.currentSetID }, set: { if let id = $0 { model.selectSet(id) } })) {
                Section(model.movement.name) {
                    ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                        SetRow(set: set, isPreset: index == 0, counts: (try? model.show.moveCounts(into: set.id, map: model.map)) ?? .zero,
                               music: model.show.measureLabel(for: set, map: map),
                               arrivalCount: model.show.cumulativeCount(of: set, map: map),
                               countsOnly: model.show.countingMode == .counts,
                               time: model.hasAudio ? (try? map?.audioTime(at: set.cursor)).flatMap { $0 }.map(TimeFormat.clock) : nil)
                    }
                }
            }
            .fwSidebarList()
            HStack(spacing: Tokens.Space.xs) {
                Menu {
                    ForEach([4, 8, 12, 16, 24, 32], id: \.self) { counts in
                        Button("\(counts) counts") { model.addSet(counts: counts) }
                    }
                } label: {
                    Label("Add Set", systemImage: "plus")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fwSecondaryButton()
                .fixedSize()
                .help("Add a set after the current one, copying its formation")
                .tourAnchor("navigator.addSet")
                .accessibilityIdentifier("navigator.addSet")
                Menu {
                    ForEach([4, 8, 12, 16, 24, 32], id: \.self) { counts in
                        Button("\(counts) counts") { model.drawNextSet(counts: counts) }
                    }
                } label: {
                    Label("Draw Next Set", systemImage: "pencil.and.outline").labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fwSecondaryButton()
                .fixedSize()
                .help("Draw Next Set: add a set after the current one, draw its shapes over the previous set, then let Auto Route choose who goes where")
                .disabled(!model.isEditable)
                Spacer(minLength: 0)
                Button { model.deleteCurrentSet() } label: { Image(systemName: "trash") }
                    .fwSecondaryButton()
                    .help("Delete the current set")
                    .accessibilityLabel("Delete set")
                    .disabled(model.show.previousSet(before: model.currentSetID) == nil)
            }
            .controlSize(.small)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, Tokens.Space.s)
            .padding(.vertical, Tokens.Space.s)
            .frame(maxWidth: .infinity)
            .glassGroup(spacing: Tokens.Space.xs)
        }
    }

    private var rosterList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.fwSecondary)
                TextField("Search performers", text: $search)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.fwSecondary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                }
            }
            .font(.system(size: 12))
            .fwField()
            .clipShape(Capsule())
            .padding(.horizontal, Tokens.Space.s)
            // Native list selection: click selects one, Command-click adds or removes, Shift-click selects a range.
            List(selection: $model.selection) {
                ForEach(model.show.sections) { section in
                    let members = model.show.performers(in: section.id).filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }
                    Section {
                        ForEach(members) { performer in
                            HStack {
                                SymbolGlyph(symbol: model.displaySymbol(for: performer), colorIndex: section.colorIndex)
                                Text(performer.label).monospacedDigit()
                                Spacer()
                                if model.show.formation(model.currentSetID)[performer.id].position == nil {
                                    Label("No position", systemImage: "questionmark.circle")
                                        .labelStyle(.iconOnly)
                                        .foregroundStyle(Color.fwWarning)
                                        .help("No position at this set")
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("\(section.name) (\(model.show.performers(in: section.id).count))")
                            Spacer()
                            SectionSymbolButton(model: model, section: section)
                            SectionLetterButton(model: model, section: section)
                            Button("Select") {
                                if NSEvent.modifierFlags.contains(.command) {
                                    model.selection.formUnion(model.show.performers(in: section.id).map(\.id))
                                } else {
                                    model.selectSection(section.id)
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .help("Select this section. Command-click to add it to the selection.")
                        }
                    }
                }
            }
            .fwSidebarList()
            HStack {
                Button { model.showAddSection = true } label: { Label("Add Section", systemImage: "person.badge.plus") }
                    .fwSecondaryButton()
                    .controlSize(.small)
                    .tourAnchor("roster.add")
                    .accessibilityIdentifier("roster.add")
                Spacer()
                Text("\(model.show.performers.count) performers").font(.caption).foregroundStyle(Color.fwSecondary)
            }
            .padding(Tokens.Space.s)
        }
    }
}

struct SetRow: View {
    var set: ArrivalSet
    var isPreset: Bool
    var counts: Rational
    var music: String
    var arrivalCount: Rational?
    var countsOnly: Bool
    var time: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Set \(set.label)").font(.system(size: 13, weight: .semibold))
                if !set.rehearsalMark.isEmpty {
                    Text(set.rehearsalMark)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .foregroundStyle(Color.fwAccent)
                        .background(Capsule().fill(Color.fwAccent.opacity(0.18)))
                        .accessibilityLabel("Rehearsal mark \(set.rehearsalMark)")
                }
                if !set.notes.isEmpty {
                    Image(systemName: "note.text").font(.system(size: 10)).foregroundStyle(Color.fwSecondary).accessibilityLabel("Has notes")
                }
                Spacer(minLength: 4)
                if let time { Text(time).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(Color.fwSecondary) }
            }
            Text(detail)
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(Color.fwSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    /// Measures mode: "Arrival m17 b1 · move 16 counts". Counts mode: "Count 208 · 16 counts · m. 222-223".
    private var detail: String {
        let move = "\(TimeFormat.decimal(counts.doubleValue, places: counts.isInteger ? 0 : 2)) counts"
        if countsOnly {
            let count = arrivalCount.map { "Count \(TimeFormat.decimal($0.doubleValue, places: $0.isInteger ? 0 : 2))" } ?? ""
            let parts = isPreset ? ["Preset", music] : [count, move, music]
            return parts.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if isPreset { return ["Preset · count 0", music].filter { !$0.isEmpty }.joined(separator: " · ") }
        return music.isEmpty ? "Move \(move)" : "Arrival \(music) · move \(move)"
    }
}

/// Shows a section's symbol; clicking it picks the symbol every member uses,
/// except members given their own symbol in the inspector.
struct SectionSymbolButton: View {
    @ObservedObject var model: EditorModel
    var section: DrillCore.Section
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            SymbolGlyph(symbol: section.symbol, colorIndex: section.colorIndex)
                .padding(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Change the symbol for \(section.name)")
        .accessibilityLabel("Symbol \(section.symbol.displayName) for \(section.name). Change")
        .disabled(!model.isEditable)
        .popover(isPresented: $editing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                Text("\(section.name) symbol").font(.headline)
                SymbolPicker(selection: section.symbol, colorIndex: section.colorIndex) { symbol in
                    if let symbol, symbol != section.symbol { model.setSectionSymbol(section.id, symbol: symbol) }
                    editing = false
                }
                .disabled(model.circlesOnly)
                let custom = model.show.performers(in: section.id).filter { $0.symbol != nil }.map(\.id)
                Text(custom.isEmpty ? "Every \(section.name) performer uses this symbol."
                     : "\(custom.count) performer\(custom.count == 1 ? " has" : "s have") their own symbol and keep\(custom.count == 1 ? "s" : "") it.")
                    .font(.caption).foregroundStyle(Color.fwSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !custom.isEmpty {
                    Button("Use the Section Symbol for All") { model.setSymbol(custom, symbol: nil) }
                        .help("Return the \(custom.count) performer\(custom.count == 1 ? "" : "s") with their own symbol to the \(section.name) symbol")
                }
                if model.circlesOnly {
                    Text("Turn off View › Draw Everyone as Circles to change symbols.")
                        .font(.caption).foregroundStyle(Color.fwSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Tokens.Space.l)
            .frame(width: 280)
        }
    }
}

/// Shows a section's label letter; clicking it changes the letter and
/// relabels the section's performers (T3 → TS3) in one undoable edit.
struct SectionLetterButton: View {
    @ObservedObject var model: EditorModel
    var section: DrillCore.Section
    @State private var editing = false
    @State private var letter = ""

    var body: some View {
        Button(section.prefix) {
            letter = section.prefix
            editing = true
        }
        .buttonStyle(.borderless)
        .font(.caption.monospaced())
        .help("Change the label letter for \(section.name)")
        .accessibilityLabel("Label letter \(section.prefix) for \(section.name). Change")
        .disabled(!model.isEditable)
        .popover(isPresented: $editing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                Text("\(section.name) label letter").font(.headline)
                TextField("Letter", text: $letter)
                    .frame(width: 120)
                    .onSubmit(apply)
                Text("Performers labeled \(section.prefix)1, \(section.prefix)2… are relabeled. Labels you changed by hand stay as they are.")
                    .font(.caption).foregroundStyle(Color.fwSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
                    Button("Change", action: apply)
                        .keyboardShortcut(.defaultAction)
                        .disabled(letter.trimmingCharacters(in: .whitespaces).isEmpty || letter == section.prefix)
                }
            }
            .padding(Tokens.Space.l)
            .frame(width: 280)
        }
    }

    private func apply() {
        guard !letter.trimmingCharacters(in: .whitespaces).isEmpty, letter != section.prefix else { return }
        model.setSectionPrefix(section.id, prefix: letter)
        editing = false
    }
}
