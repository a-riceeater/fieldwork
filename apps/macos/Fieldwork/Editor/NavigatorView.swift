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
            Picker("", selection: $tab) {
                Text("Sets").tag(0)
                Text("Roster").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Tokens.Space.s)
            if tab == 0 { setsList } else { rosterList }
        }
        .background(Color.fwSurface)
    }

    private var setsList: some View {
        let map = model.map
        let sets = model.setsInMovement
        return VStack(spacing: 0) {
            List(selection: Binding(get: { model.currentSetID }, set: { if let id = $0 { model.selectSet(id) } })) {
                Section(model.movement.name) {
                    ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                        SetRow(set: set, isPreset: index == 0, counts: (try? model.show.moveCounts(into: set.id)) ?? .zero,
                               music: (try? map?.musicalPosition(at: set.cursor).label) ?? "",
                               time: model.hasAudio ? (try? map?.audioTime(at: set.cursor)).flatMap { $0 }.map(TimeFormat.clock) : nil)
                            .tag(set.id)
                    }
                }
            }
            .listStyle(.sidebar)
            HStack {
                Menu {
                    ForEach([4, 8, 12, 16, 24, 32], id: \.self) { counts in
                        Button("\(counts) counts") { model.addSet(counts: counts) }
                    }
                } label: {
                    Label("Add Set", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a set after the current one, copying its formation")
                .tourAnchor("navigator.addSet")
                .accessibilityIdentifier("navigator.addSet")
                Spacer()
                Button { model.deleteCurrentSet() } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .help("Delete the current set")
                    .accessibilityLabel("Delete set")
                    .disabled(model.show.previousSet(before: model.currentSetID) == nil)
            }
            .padding(Tokens.Space.s)
        }
    }

    private var rosterList: some View {
        VStack(spacing: 0) {
            TextField("Search performers", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, Tokens.Space.s)
            List {
                ForEach(model.show.sections) { section in
                    let members = model.show.performers(in: section.id).filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }
                    Section {
                        ForEach(members) { performer in
                            Button {
                                model.selection = [performer.id]
                            } label: {
                                HStack {
                                    Circle().fill(Color(nsColor: Tokens.sectionColor(section.colorIndex))).frame(width: 8, height: 8)
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
                            .buttonStyle(.plain)
                            .listRowBackground(model.selection.contains(performer.id) ? Color.fwAccent.opacity(0.15) : Color.clear)
                        }
                    } header: {
                        HStack {
                            Text("\(section.name) (\(model.show.performers(in: section.id).count))")
                            Spacer()
                            Button("Select") { model.selectSection(section.id) }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            HStack {
                Button { model.showAddSection = true } label: { Label("Add Section", systemImage: "person.badge.plus") }
                    .buttonStyle(.borderless)
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
    var time: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Set \(set.label)").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !set.notes.isEmpty { Image(systemName: "note.text").foregroundStyle(Color.fwSecondary).accessibilityLabel("Has notes") }
            }
            Text(isPreset ? "Preset · count 0 · \(music)" : "Arrival \(music) · move \(TimeFormat.decimal(counts.doubleValue, places: counts.isInteger ? 0 : 2)) counts")
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(Color.fwSecondary)
            if let time { Text(time).font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.fwSecondary) }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
