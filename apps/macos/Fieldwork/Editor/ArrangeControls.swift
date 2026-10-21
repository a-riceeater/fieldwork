import SwiftUI
import DrillTiming
import DrillCore

extension QuickShape {
    var symbol: String {
        switch self {
        case .line: return "line.diagonal"
        case .arc: return "rainbow"
        case .block: return "square.grid.3x3"
        case .circle: return "circle.dashed"
        }
    }

    var help: String {
        switch self {
        case .line: return "Put the selection in a straight line you can reshape with handles"
        case .arc: return "Put the selection in an arc you can reshape with handles"
        case .block: return "Put the selection in a block, rows front to back"
        case .circle: return "Put the selection in a circle you can resize with handles"
        }
    }
}

/// Shape buttons plus the spacing menu, shared by the canvas bar and the inspector.
struct ArrangeButtons: View {
    @ObservedObject var model: EditorModel
    var showsTitles = true

    var body: some View {
        ForEach(QuickShape.allCases, id: \.self) { shape in
            Button { model.placeSelection(in: shape) } label: {
                if showsTitles {
                    Label(shape.displayName, systemImage: shape.symbol)
                } else {
                    Image(systemName: shape.symbol)
                }
            }
            .help(shape.help)
            .accessibilityLabel("Arrange in \(shape.displayName)")
        }
        SpellButton(model: model, showsTitle: showsTitles)
        SpacingMenu(model: model)
    }
}

struct SpacingMenu: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        Menu {
            ForEach([1.0, 1.5, 2, 3, 4], id: \.self) { steps in
                Button {
                    if let form = selectedCircle {
                        model.spaceCircle(form.id, spacingSteps: steps)
                    } else {
                        model.shapeSpacingSteps = steps
                    }
                } label: {
                    if abs(spacingSteps - steps) < 0.000001 { Label(label(steps), systemImage: "checkmark") } else { Text(label(steps)) }
                }
            }
        } label: {
            Text(label(spacingSteps)).monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(selectedCircle == nil ? "Spacing between neighbors in new shapes" : "Resize the selected circle to set the distance between neighboring performers")
        .accessibilityLabel("Shape spacing")
    }

    private var selectedCircle: Form? {
        model.show.forms(on: model.currentSetID).first {
            if case .circle = $0.geometry { return Set($0.members) == model.selection }
            return false
        }
    }

    private var spacingSteps: Double {
        guard let form = selectedCircle else { return model.shapeSpacingSteps }
        return form.geometry.neighborSpacing(count: form.members.count) / model.show.field.stepSize
    }

    private func label(_ steps: Double) -> String {
        "\(TimeFormat.decimal(steps, places: steps.rounded() == steps ? 0 : 2))-step"
    }
}

/// Floating bar over the canvas whenever performers are selected on an editable set.
struct ArrangeBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        if model.isEditable, !model.selection.isEmpty, model.draft == nil {
            HStack(spacing: Tokens.Space.s) {
                Text("\(model.selection.count) selected")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                Divider().frame(height: 18)
                ArrangeButtons(model: model)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Tokens.Space.m)
            .padding(.vertical, Tokens.Space.s)
            .floatingGlass()
            .glassGroup()
            .padding(.bottom, Tokens.Space.m)
            .tourAnchor("canvas.arrange")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Arrange selection")
        }
    }
}

/// Floating prompt over the canvas while performers on this set have no position.
struct UnplacedBanner: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let count = model.unplacedCount
        if model.isEditable, count > 0, model.draft == nil {
            HStack(spacing: Tokens.Space.m) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(Color.fwWarning)
                Text("\(count) performer\(count == 1 ? " isn't" : "s aren't") on the field yet")
                    .font(.system(size: 12, weight: .medium))
                Button("Place All") { model.placeUnplaced() }
                    .fwPrimaryButton()
                    .controlSize(.small)
                    .help("Put everyone without a position into blocks by section. Undo removes them again.")
            }
            .padding(.leading, Tokens.Space.m)
            .padding(.trailing, Tokens.Space.s)
            .padding(.vertical, 6)
            .floatingGlass()
            .padding(.top, Tokens.Space.m)
            .accessibilityElement(children: .contain)
        }
    }
}
