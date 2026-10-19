import AppKit
import SwiftUI

/// Per-window pane sizes. The field receives all remaining space.
struct EditorPaneSizes {
    var navigator = Tokens.Layout.navigator
    var inspector = Tokens.Layout.inspector
    var timeline = Tokens.Layout.timeline
    static let divider: CGFloat = 4

    func fitted(to size: CGSize) -> EditorPaneSizes {
        var result = self
        result.inspector = min(inspector, max(240, size.width - 420 - 160 - 2 * Self.divider))
        result.navigator = min(navigator, max(160, size.width - 420 - result.inspector - 2 * Self.divider))
        result.timeline = min(timeline, max(170, size.height - 360 - Self.divider))
        return result
    }
}

/// Explicit initial sizes avoid giving spare width/height to the surrounding panels.
/// Everything stays in one SwiftUI tree, including toolbar and onboarding anchors.
struct EditorWorkspace: View {
    @ObservedObject var model: EditorModel
    @State private var sizes = EditorPaneSizes()

    var body: some View {
        GeometryReader { geometry in
            let fitted = sizes.fitted(to: geometry.size)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    NavigatorView(model: model).frame(width: fitted.navigator)
                    PaneDivider(title: "Sets panel width", vertical: true,
                                value: Binding(get: { fitted.navigator }, set: { sizes.navigator = $0 }),
                                limits: 160...min(320, max(160, geometry.size.width - fitted.inspector - 428)))
                    ZStack(alignment: .bottomLeading) {
                        FieldCanvas(model: model).tourAnchor("canvas.field")
                        CanvasToolCluster(model: model).padding(Tokens.Space.m)
                    }
                    .overlay(alignment: .top) { UnplacedBanner(model: model) }
                    .overlay(alignment: .bottomTrailing) { ArrangeBar(model: model).padding(.trailing, Tokens.Space.m) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    PaneDivider(title: "Inspector width", vertical: true, direction: -1,
                                value: Binding(get: { fitted.inspector }, set: { sizes.inspector = $0 }),
                                limits: 240...min(360, max(240, geometry.size.width - fitted.navigator - 428)))
                    InspectorView(model: model).frame(width: fitted.inspector)
                }
                .frame(maxHeight: .infinity)
                PaneDivider(title: "Timeline height", vertical: false, direction: -1,
                            value: Binding(get: { fitted.timeline }, set: { sizes.timeline = $0 }),
                            limits: 170...min(420, max(170, geometry.size.height - 364)))
                TimelinePanel(model: model).frame(height: fitted.timeline)
            }
        }
    }
}

/// A draggable, accessible separator with a generous pointer target and a thin rule.
private struct PaneDivider: View {
    var title: String
    var vertical: Bool
    var direction: CGFloat = 1
    @Binding var value: CGFloat
    var limits: ClosedRange<CGFloat>
    @State private var dragStart: CGFloat?

    private func set(_ proposed: CGFloat) { value = min(max(proposed, limits.lowerBound), limits.upperBound) }

    var body: some View {
        Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.45))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .frame(width: vertical ? EditorPaneSizes.divider : nil, height: vertical ? nil : EditorPaneSizes.divider)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    if dragStart == nil { dragStart = value }
                    let delta = vertical ? gesture.translation.width : gesture.translation.height
                    set((dragStart ?? value) + direction * delta)
                }
                .onEnded { _ in dragStart = nil })
            .onHover { hovering in
                (hovering ? (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown) : NSCursor.arrow).set()
            }
            .help("Drag to resize")
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityValue("\(Int(value)) points")
            .accessibilityAdjustableAction { adjustment in
                switch adjustment {
                case .increment: set(value + 16)
                case .decrement: set(value - 16)
                @unknown default: break
                }
            }
    }
}
