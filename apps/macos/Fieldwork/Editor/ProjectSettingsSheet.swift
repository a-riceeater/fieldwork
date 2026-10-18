import SwiftUI
import DrillTiming
import DrillCore

/// Show-wide settings, opened from File › Project Settings…. Edits are staged
/// in the sheet and committed as one undoable command on Apply.
struct ProjectSettingsSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var preset: Field.Preset = .highSchoolFootball
    @State private var length = 40.0
    @State private var width = 30.0

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            Text("Project Settings").font(.headline)
            InspectorSection(title: "Field") {
                Text("Current: \(model.show.field.name)").foregroundStyle(Color.fwSecondary)
                Picker("Preset", selection: $preset) {
                    ForEach(Field.Preset.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .accessibilityIdentifier("field.selector")
                if preset == .custom {
                    NumberField(label: "Length (m)", value: length, places: 2) { length = $0 }
                    NumberField(label: "Width (m)", value: width, places: 2) { width = $0 }
                }
                Text("Step size \(TimeFormat.decimal(candidate.stepSize, places: 4)) m · \(TimeFormat.decimal(5 * Field.yard / candidate.stepSize, places: 1)) to 5")
                    .font(.caption).foregroundStyle(Color.fwSecondary)
                Text("Coordinates are kept in meters; changing the field does not move performers.")
                    .font(.caption).foregroundStyle(Color.fwSecondary)
            }
            if let reason = model.readOnlyReason {
                Label(reason, systemImage: "lock").font(.caption).foregroundStyle(Color.fwWarning)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    if candidate == model.show.field { model.keepField() } else { model.applyField(candidate) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.readOnlyReason != nil)
            }
        }
        .padding(Tokens.Space.xl)
        .frame(width: 420)
        .onAppear {
            let field = model.show.field
            preset = field.preset
            length = field.length
            width = field.width
        }
    }

    /// The field Apply would commit; an unchanged selection keeps the current field.
    private var candidate: Field {
        let current = model.show.field
        if preset == .custom {
            if current.preset == .custom && length == current.length && width == current.width { return current }
            return Field.custom(length: length, width: width, stepSize: current.stepSize)
        }
        return preset == current.preset ? current : Field.make(preset)
    }
}
