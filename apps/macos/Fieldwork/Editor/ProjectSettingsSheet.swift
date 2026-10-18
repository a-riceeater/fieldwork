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
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Project Settings").font(.system(size: 20, weight: .bold))
                Text("Field for \(model.show.title)").foregroundStyle(Color.fwSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], Tokens.Space.xl)
            .padding(.bottom, Tokens.Space.m)

            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.l) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Tokens.Space.m)], spacing: Tokens.Space.m) {
                        ForEach(Field.Preset.allCases, id: \.self) { option in
                            FieldPresetCard(field: field(for: option), title: option.displayName, isSelected: preset == option) {
                                preset = option
                            }
                        }
                    }
                    .accessibilityIdentifier("field.selector")
                    if preset == .custom {
                        HStack(spacing: Tokens.Space.xl) {
                            NumberField(label: "Length (m)", value: length, places: 2) { length = max(1, $0) }
                            NumberField(label: "Width (m)", value: width, places: 2) { width = max(1, $0) }
                        }
                        .padding(Tokens.Space.m)
                        .fwCard()
                    }
                    Label("Coordinates are kept in meters; changing the field does not move performers.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(Color.fwSecondary)
                    if let reason = model.readOnlyReason {
                        Label(reason, systemImage: "lock.fill").font(.caption).foregroundStyle(Color.fwWarning)
                    }
                }
                .padding(.horizontal, Tokens.Space.xl)
                .padding(.bottom, Tokens.Space.l)
            }

            Divider()
            HStack(spacing: Tokens.Space.s) {
                Text("Step size \(TimeFormat.decimal(candidate.stepSize, places: 4)) m · \(TimeFormat.decimal(5 * Field.yard / candidate.stepSize, places: 1)) to 5")
                    .font(.caption)
                    .foregroundStyle(Color.fwSecondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .fwSecondaryButton()
                Button("Apply") {
                    if candidate == model.show.field { model.keepField() } else { model.applyField(candidate) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .fwPrimaryButton()
                .disabled(model.readOnlyReason != nil)
            }
            .controlSize(.large)
            .padding(.horizontal, Tokens.Space.xl)
            .padding(.vertical, Tokens.Space.m)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 640)
        .onAppear {
            let field = model.show.field
            preset = field.preset
            length = field.length
            width = field.width
        }
    }

    /// The picture for each card; Custom previews the dimensions being edited.
    private func field(for option: Field.Preset) -> Field {
        option == .custom ? Field.custom(length: length, width: width, stepSize: model.show.field.stepSize) : Field.make(option)
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
