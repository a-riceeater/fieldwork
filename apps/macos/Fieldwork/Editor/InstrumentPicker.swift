import SwiftUI
import DrillCore

/// Section dropdown: common instruments grouped by family (color guard
/// included), plus Other with a custom name. Choosing an instrument fills in
/// its drill letter; a custom name suggests its first letter.
struct InstrumentPicker: View {
    @Binding var name: String
    @Binding var prefix: String
    @State private var isOther: Bool

    init(name: Binding<String>, prefix: Binding<String>) {
        _name = name
        _prefix = prefix
        _isOther = State(initialValue: InstrumentPreset.named(name.wrappedValue) == nil)
    }

    var body: some View {
        HStack {
            Picker("Section", selection: selection) {
                ForEach(InstrumentPreset.Family.allCases, id: \.self) { family in
                    SwiftUI.Section(family.displayName) {
                        ForEach(InstrumentPreset.family(family)) { preset in
                            Text("\(preset.name) (\(preset.prefix))").tag(Optional(preset.name))
                        }
                    }
                }
                Divider()
                Text("Other…").tag(String?.none)
            }
            .accessibilityLabel("Section")
            if isOther {
                TextField("Section name", text: $name)
                    .onChange(of: name) { _, value in prefix = value.first.map { String($0).uppercased() } ?? "" }
                    .accessibilityLabel("Custom section name")
            }
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { isOther ? nil : InstrumentPreset.named(name)?.name },
            set: { choice in
                if let choice, let preset = InstrumentPreset.named(choice) {
                    isOther = false
                    name = preset.name
                    prefix = preset.prefix
                } else {
                    isOther = true
                    name = ""
                    prefix = ""
                }
            })
    }
}
