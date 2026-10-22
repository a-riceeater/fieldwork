import AppKit
import SwiftUI
import DrillCore

// MARK: Window and buttons

/// Behind-window material for window backgrounds and sidebars. The system
/// swaps it for an opaque color when Reduce Transparency is on.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

extension View {
    /// Prominent action: Liquid Glass on macOS 26, bordered prominent before.
    @ViewBuilder
    func fwPrimaryButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// Secondary action: Liquid Glass on macOS 26, bordered before.
    @ViewBuilder
    func fwSecondaryButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// A quiet grouped surface for content (not glass: content stays legible).
    func fwCard(cornerRadius: CGFloat = Tokens.Radius.panel, selected: Bool = false) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.07 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(selected ? Color.fwAccent : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
        )
    }

    /// A borderless grouped surface for inspector content, like the grouped
    /// rows in System Settings. Not glass: content stays legible.
    func fwGroup(cornerRadius: CGFloat = Tokens.Radius.group) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    /// An inline value field: plain text on a soft rounded fill with an accent
    /// ring while editing, in place of the boxed `.roundedBorder` bezel.
    func fwField(focused: Bool = false) -> some View {
        modifier(InlineFieldChrome(focused: focused))
    }

    /// A rounded panel inset from the window edge and its neighbors, like a
    /// macOS 26 sidebar. `material` uses the sidebar material; otherwise the
    /// opaque surface, for panels such as the timeline that need steady contrast.
    func fwPanel(material: Bool = true) -> some View {
        modifier(FloatingPanel(material: material))
    }
}

private struct InlineFieldChrome: ViewModifier {
    var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    private let shape = RoundedRectangle(cornerRadius: Tokens.Radius.field, style: .continuous)

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(shape.fill(Color.primary.opacity(focused ? 0.035 : 0.07)))
            .overlay(shape.strokeBorder(focused ? Color.fwAccent : Color.primary.opacity(contrast == .increased ? 0.35 : 0),
                                        lineWidth: focused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

private struct FloatingPanel: ViewModifier {
    var material: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    private let shape = RoundedRectangle(cornerRadius: Tokens.Radius.floatingPanel, style: .continuous)

    func body(content: Content) -> some View {
        content
            .background {
                if material { VisualEffectBackground(material: .sidebar) } else { Color.fwSurface }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.3 : 0.08)))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 1)
            .padding(Tokens.Layout.panelInset)
    }
}

/// Large tappable row used on the welcome screen: icon tile, title, subtitle.
/// Interactive Liquid Glass on macOS 26; material with a hover highlight before.
struct ActionTile: View {
    var title: String
    var subtitle: String
    var systemImage: String
    var prominent = false
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.m) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(prominent ? Color.white : Color.fwAccent)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(prominent ? Color.fwAccent : Color.fwAccent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Color.fwSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, Tokens.Space.m)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .modifier(TileSurface(hovering: hovering, reduceTransparency: reduceTransparency))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}

private struct TileSurface: ViewModifier {
    var hovering: Bool
    var reduceTransparency: Bool
    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    func body(content: Content) -> some View {
        if reduceTransparency {
            plain(content)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            plain(content)
        }
    }

    private func plain(_ content: Content) -> some View {
        content
            .background(shape.fill(Color.primary.opacity(hovering ? 0.08 : 0.04)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Numbered steps with connectors; completed steps can be revisited.
struct StepIndicator: View {
    var titles: [String]
    var current: Int
    var select: (Int) -> Void

    var body: some View {
        HStack(spacing: Tokens.Space.s) {
            ForEach(titles.indices, id: \.self) { i in
                Button { select(i) } label: {
                    HStack(spacing: 6) {
                        ZStack {
                            Circle().fill(i <= current ? Color.fwAccent : Color.primary.opacity(0.08))
                            if i < current {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            } else {
                                Text("\(i + 1)").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(i == current ? Color.white : Color.fwSecondary)
                            }
                        }
                        .frame(width: 22, height: 22)
                        Text(titles[i])
                            .font(.system(size: 13, weight: i == current ? .semibold : .regular))
                            .foregroundStyle(i == current ? Color.primary : Color.fwSecondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(i > current)
                if i < titles.count - 1 {
                    Capsule()
                        .fill(i < current ? Color.fwAccent : Color.primary.opacity(0.12))
                        .frame(width: 28, height: 2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(current + 1) of \(titles.count): \(titles[current])")
    }
}

/// Two choice cards for how sets relate to the music.
struct CountingModePicker: View {
    @Binding var mode: CountingMode

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.m) {
            card(.measures, systemImage: "music.note.list",
                 detail: "Sets show the measure and beat from the timeline. Best when you write to the score.")
            card(.counts, systemImage: "number",
                 detail: "Sets are pages of counts. Meter changes don't matter; type measure numbers yourself, like 222-223.")
        }
    }

    private func card(_ option: CountingMode, systemImage: String, detail: String) -> some View {
        Button { mode = option } label: {
            HStack(alignment: .top, spacing: Tokens.Space.s) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.fwAccent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.displayName).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(Color.fwSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: mode == option ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(mode == option ? Color.fwAccent : Color.primary.opacity(0.25))
            }
            .padding(Tokens.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .fwCard(cornerRadius: 12, selected: mode == option)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(option.displayName). \(detail)")
        .accessibilityAddTraits(mode == option ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: Field pictures

extension Field {
    var isFootball: Bool { [.highSchoolFootball, .collegeFootball, .proFootball].contains(preset) }

    /// "120 × 53⅓ yd", "90 × 60 ft" or "40 × 30 m".
    var sizeSummary: String {
        if isFootball { return "\(Self.compact(length / Field.yard)) × \(Self.compact(width / Field.yard)) yd" }
        if preset == .indoorFloor { return "\(Self.compact(length / Field.foot)) × \(Self.compact(width / Field.foot)) ft" }
        return "\(Self.compact(length)) × \(Self.compact(width)) m"
    }

    /// Hash placement for football fields, the reference grid otherwise.
    var detailSummary: String {
        if isFootball, let hash = checkpoints.first(where: { $0.axis == .y && $0.prominence == .hash }) {
            let inches = Int(((hash.position + width / 2) / Field.foot * 12).rounded())
            return "Hashes \(inches / 12) ft\(inches % 12 == 0 ? "" : " \(inches % 12) in") from sideline"
        }
        return preset == .indoorFloor ? "Lettered lines every 10 ft" : "Reference lines every 8 steps"
    }

    private static func compact(_ value: Double) -> String {
        let whole = value.rounded(.down)
        let fraction = value - whole
        if abs(fraction) < 0.02 { return String(Int(whole)) }
        if abs(fraction - 1.0 / 3) < 0.02 { return "\(Int(whole))⅓" }
        if abs(fraction - 2.0 / 3) < 0.02 { return "\(Int(whole))⅔" }
        if abs(fraction - 0.5) < 0.02 { return "\(Int(whole))½" }
        if fraction > 0.98 { return String(Int(whole) + 1) }
        return String(format: "%.1f", value)
    }
}

/// Top-down drawing of a field from its checkpoints: mowed grass (or a tarp
/// for indoor floors), yard lines, hashes and yard numbers, front at the bottom.
struct FieldThumbnail: View {
    var field: Field

    private static let grass = Color(nsColor: Tokens.Turf.grass)
    private static let stripe = Color(nsColor: Tokens.Turf.stripe)
    private static let endZone = Color(nsColor: Tokens.Turf.endZone)
    private static let tarp = Color(nsColor: Tokens.Turf.tarp)

    var body: some View {
        Canvas { context, size in
            let field = self.field
            let s = size.width / field.length
            func px(_ x: Double) -> CGFloat { CGFloat((x + field.length / 2) * s) }
            func py(_ y: Double) -> CGFloat { CGFloat((field.width / 2 - y) * s) }
            func line(_ a: CGPoint, _ b: CGPoint) -> Path { var p = Path(); p.move(to: a); p.addLine(to: b); return p }

            let full = CGRect(origin: .zero, size: size)
            context.fill(Path(full), with: .color(field.preset == .indoorFloor ? Self.tarp : Self.grass))

            let yard = Field.yard
            let goal = 50 * yard
            if field.isFootball {
                for i in stride(from: 0, to: 20, by: 2) {
                    let x0 = -goal + Double(i) * 5 * yard
                    context.fill(Path(CGRect(x: px(x0), y: 0, width: CGFloat(5 * yard * s), height: size.height)), with: .color(Self.stripe))
                }
                context.fill(Path(CGRect(x: 0, y: 0, width: px(-goal), height: size.height)), with: .color(Self.endZone))
                context.fill(Path(CGRect(x: px(goal), y: 0, width: size.width - px(goal), height: size.height)), with: .color(Self.endZone))
            }

            let thin = max(0.6, 0.12 * yard * s)
            for cp in field.checkpoints where cp.axis == .x {
                let x = min(max(px(cp.position), thin), size.width - thin)
                let major = cp.prominence == .major
                context.stroke(line(CGPoint(x: x, y: 0), CGPoint(x: x, y: size.height)),
                               with: .color(.white.opacity(major ? 0.92 : 0.6)), lineWidth: major ? thin * 1.6 : thin)
            }
            for cp in field.checkpoints where cp.axis == .y {
                let y = min(max(py(cp.position), thin), size.height - thin)
                if cp.prominence == .hash {
                    let span = field.isFootball ? (px(-goal), px(goal)) : (0, size.width)
                    let dash = max(1, CGFloat(0.4 * yard * s))
                    context.stroke(line(CGPoint(x: span.0, y: y), CGPoint(x: span.1, y: y)), with: .color(.white.opacity(0.85)),
                                   style: StrokeStyle(lineWidth: max(1, thin * 2.2), dash: [dash, max(1, CGFloat(yard * s) - dash)]))
                } else {
                    context.stroke(line(CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y)), with: .color(.white.opacity(0.92)), lineWidth: thin * 1.6)
                }
            }

            if field.isFootball && size.width > 200 {
                let fontSize = CGFloat(2 * yard * s)
                for cp in field.checkpoints where cp.axis == .x {
                    guard let n = Int(cp.label), n % 10 == 0, n > 0 else { continue }
                    for y in [-field.width / 2 + 10 * yard, field.width / 2 - 10 * yard] {
                        context.draw(Text(cp.label).font(.system(size: fontSize, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.85)),
                                     at: CGPoint(x: px(cp.position), y: py(y)))
                    }
                }
            }
        }
        .aspectRatio(field.length / field.width, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .accessibilityHidden(true)
    }
}

/// A selectable card with a field picture, its name and its size.
struct FieldPresetCard: View {
    var field: Field
    var title: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                Color.clear
                    .aspectRatio(2.2, contentMode: .fit)
                    .overlay(FieldThumbnail(field: field).padding(Tokens.Space.xs))
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        Text(field.sizeSummary).font(.system(size: 12)).monospacedDigit()
                        Text(field.detailSummary).font(.system(size: 11)).foregroundStyle(Color.fwSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? Color.fwAccent : Color.primary.opacity(0.25))
                }
            }
            .padding(Tokens.Space.m)
            .contentShape(Rectangle())
            .fwCard(cornerRadius: 14, selected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(field.sizeSummary), \(field.detailSummary)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: Performer symbols

/// A performer symbol in a section color, drawn like the field canvas draws it.
struct SymbolGlyph: View {
    var symbol: PerformerSymbol
    var colorIndex: Int
    var size: CGFloat = 9

    var body: some View {
        Canvas { ctx, canvasSize in
            let r = min(canvasSize.width, canvasSize.height) / 2
            let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let color = Color(nsColor: Tokens.sectionColor(colorIndex))
            let stroke = StrokeStyle(lineWidth: max(1.5, r * 0.35), lineCap: .round)
            var path = Path()
            switch symbol {
            case .circle:
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
            case .square:
                ctx.fill(Path(CGRect(x: c.x - r * 0.9, y: c.y - r * 0.9, width: 1.8 * r, height: 1.8 * r)), with: .color(color))
            case .triangle:
                path.addLines([CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x + r, y: c.y + r * 0.8), CGPoint(x: c.x - r, y: c.y + r * 0.8)])
                path.closeSubpath()
                ctx.fill(path, with: .color(color))
            case .diamond:
                path.addLines([CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x + r, y: c.y), CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x - r, y: c.y)])
                path.closeSubpath()
                ctx.fill(path, with: .color(color))
            case .cross:
                path.move(to: CGPoint(x: c.x - r, y: c.y - r)); path.addLine(to: CGPoint(x: c.x + r, y: c.y + r))
                path.move(to: CGPoint(x: c.x - r, y: c.y + r)); path.addLine(to: CGPoint(x: c.x + r, y: c.y - r))
                ctx.stroke(path, with: .color(color), style: stroke)
            case .slash:
                path.move(to: CGPoint(x: c.x - r, y: c.y + r)); path.addLine(to: CGPoint(x: c.x + r, y: c.y - r))
                ctx.stroke(path, with: .color(color), style: stroke)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A row of symbol buttons. With `allowsSection`, the first choice is
/// "follow the section" (reported as nil).
struct SymbolPicker: View {
    /// The current choice; nil means following the section.
    var selection: PerformerSymbol?
    var colorIndex: Int
    var allowsSection = false
    /// The section's symbol when every performer shares one section.
    var sectionSymbol: PerformerSymbol? = nil
    /// False when a multiple selection has mixed choices, so nothing is highlighted.
    var showsSelection = true
    var pick: (PerformerSymbol?) -> Void

    var body: some View {
        HStack(spacing: Tokens.Space.xs) {
            if allowsSection {
                choice(nil, glyph: sectionSymbol ?? .circle,
                       name: sectionSymbol.map { "Section symbol (\($0.displayName))" } ?? "Each performer's section symbol")
                Divider().frame(height: 18)
            }
            ForEach(PerformerSymbol.allCases, id: \.self) { symbol in
                choice(symbol, glyph: symbol, name: symbol.displayName)
            }
        }
    }

    private func choice(_ value: PerformerSymbol?, glyph: PerformerSymbol, name: String) -> some View {
        let selected = showsSelection && value == selection
        return Button { pick(value) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.fwAccent.opacity(0.18) : Color.primary.opacity(0.05))
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Color.fwAccent : Color.clear, lineWidth: 1.5)
                SymbolGlyph(symbol: glyph, colorIndex: colorIndex, size: 11)
                if value == nil {
                    Text("S").font(.system(size: 7, weight: .bold)).foregroundStyle(Color.fwSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(2)
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
