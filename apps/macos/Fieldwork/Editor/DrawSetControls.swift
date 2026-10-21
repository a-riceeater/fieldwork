import SwiftUI
import DrillCore

/// Floating bar over the canvas while drawing the next set: the shape tools,
/// the previous-set overlay, who fills the shapes, and Auto Route.
struct DrawSetBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        if let draft = model.draft {
            let preview = model.draftPreview
            let members = model.draftMembers.count
            VStack(spacing: Tokens.Space.xs) {
                HStack(spacing: Tokens.Space.s) {
                    Picker("Shape", selection: Binding(get: { draft.tool }, set: { model.draft?.tool = $0 })) {
                        ForEach(DrawTool.allCases) { tool in
                            Label(tool.title, systemImage: tool.symbol).tag(tool)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Drag on the field to draw. Line, Arc and Text run from where you press to where you let go; Block goes corner to corner; Circle grows out from its center. Curve: click start and end, click between to shape, drag points to adjust, Return to finish, Escape to cancel.")
                    if draft.tool == .text {
                        TextField("Text to spell", text: $model.shapeText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            .help("Letters, numbers and . , ' ! ? - + / & #. Drag along the bottom of the letters.")
                    }
                    Divider().frame(height: 18)
                    Toggle(isOn: Binding(get: { draft.showsPreviousSet }, set: { model.draft?.showsPreviousSet = $0 })) {
                        Label("Previous Set", systemImage: "circle.dotted")
                    }
                    .toggleStyle(.button)
                    .help("Show where everyone stood at the previous set, faintly, behind the shapes")
                    DraftPerformersMenu(model: model, draft: draft)
                    Button { model.removeLastDraftShape() } label: { Image(systemName: "arrow.uturn.backward") }
                        .help("Remove the last shape (Delete)")
                        .accessibilityLabel("Remove last shape")
                        .disabled(draft.shapes.isEmpty)
                    Button { model.clearDraftShapes() } label: { Image(systemName: "trash") }
                        .help("Remove every shape")
                        .accessibilityLabel("Clear shapes")
                        .disabled(draft.shapes.isEmpty)
                    Divider().frame(height: 18)
                    Button(draft.routed ? "Route Again" : "Auto Route") { model.autoRouteDraft() }
                        .fwPrimaryButton()
                        .disabled(!model.isEditable || draft.shapes.isEmpty || members == 0 || (try? preview.get()) == nil)
                        .help("Fill the shapes with the chosen performers, each taking the nearest spot so nobody crosses the field. Undo removes the route.")
                    Button("Done") { model.finishDraft() }
                        .help("Stop drawing and edit this set as usual")
                }
                summary(draft, preview: preview, members: members)
                    .font(.caption)
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Tokens.Space.m)
            .padding(.vertical, Tokens.Space.s)
            .floatingGlass()
            .glassGroup()
            .padding(.bottom, Tokens.Space.m)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Draw next set")
        }
    }

    @ViewBuilder
    private func summary(_ draft: SetDraft, preview: Result<[Point2], DrillError>, members: Int) -> some View {
        let label = model.currentSet.map { "Set \($0.label)" } ?? "this set"
        let problem: String? = {
            if case .failure(let error) = preview { return error.message }
            return nil
        }()
        if let problem, !draft.shapes.isEmpty {
            Text(problem).foregroundStyle(Color.fwWarning)
        } else if draft.shapes.isEmpty {
            Text(draft.tool == .curve ? "Click the start and end, then add shaping points between them. Choose Finish Curve above the field (or press Return)." : "Drag on the field to draw the shapes for \(label). \(members) performers will fill them.")
                .foregroundStyle(Color.fwSecondary)
        } else {
            let others = model.show.performers.count - members
            let shapes = draft.shapes.count == 1 ? "1 shape" : "\(draft.shapes.count) shapes"
            Text("\(members) performers across \(shapes)\(others > 0 ? " · \(others) stay where they were" : "")")
                .foregroundStyle(Color.fwSecondary)
        }
    }
}

/// Which sections fill the drawn shapes; everyone else holds their previous spot.
private struct DraftPerformersMenu: View {
    @ObservedObject var model: EditorModel
    var draft: SetDraft

    var body: some View {
        Menu {
            Button("Everyone") { model.draft?.sections = Set(model.show.sections.map(\.id)) }
            Divider()
            ForEach(model.show.sections) { section in
                let title = "\(section.name) (\(model.show.performers(in: section.id).count))"
                Button { model.toggleDraftSection(section.id) } label: {
                    if draft.sections.contains(section.id) { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            Label("\(model.draftMembers.count) performers", systemImage: "person.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which sections fill the shapes. Everyone else stays where they were at the previous set.")
        .accessibilityLabel("Performers who fill the shapes")
    }
}

/// Spells typed text with the selection, from a small popover.
struct SpellButton: View {
    @ObservedObject var model: EditorModel
    var showsTitle = true
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            if showsTitle {
                Label("Text", systemImage: "textformat")
            } else {
                Image(systemName: "textformat")
            }
        }
        .help("Spell letters or numbers with the selection")
        .accessibilityLabel("Arrange as text")
        .popover(isPresented: $editing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                Text("Spell with \(model.selection.count) performers").font(.headline)
                TextField("Text to spell", text: $model.shapeText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(place)
                Text("Letters, numbers and . , ' ! ? - + / & #. To size and tilt it yourself, choose the Text tool and drag along the bottom of the letters.")
                    .font(.caption)
                    .foregroundStyle(Color.fwSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Spell", action: place)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Tokens.Space.m)
            .frame(width: 240)
        }
    }

    private func place() {
        editing = false
        model.placeSelectionInText()
    }
}
