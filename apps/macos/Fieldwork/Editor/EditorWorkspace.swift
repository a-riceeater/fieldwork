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
    @State private var showsPlaybackControls = true
    /// The pointer is over the playback bar or scrubbing it, so it must not fade.
    @State private var playbackControlsHeld = false
    @State private var pointerOverCanvas = false
    @State private var hideControlsTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let fitted = sizes.fitted(to: geometry.size)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if !model.focusesCanvas {
                        NavigatorView(model: model).frame(width: fitted.navigator)
                        PaneDivider(title: "Sets panel width", vertical: true,
                                    value: Binding(get: { fitted.navigator }, set: { sizes.navigator = $0 }),
                                    limits: 160...min(320, max(160, geometry.size.width - fitted.inspector - 428)))
                    }
                    ZStack(alignment: .bottomLeading) {
                        FieldCanvas(model: model)
                            .clipped()
                            .tourAnchor("canvas.field")
                        CanvasToolCluster(model: model).padding(Tokens.Space.m)
                    }
                    .overlay(alignment: .top) { UnplacedBanner(model: model) }
                    .overlay(alignment: .bottomTrailing) { ArrangeBar(model: model).padding(.trailing, Tokens.Space.m) }
                    .overlay(alignment: .bottom) { DrawSetBar(model: model).padding(.horizontal, Tokens.Space.m) }
                    .overlay(alignment: .bottom) {
                        if model.focusesCanvas, model.draft == nil, showsPlaybackControls {
                            FocusPlaybackBar(model: model, position: model.playbackPosition, isHeld: $playbackControlsHeld)
                                .padding(Tokens.Space.m)
                                .transition(.opacity)
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active: pointerOverCanvas = true
                        case .ended: pointerOverCanvas = false
                        }
                        revealPlaybackControls()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !model.focusesCanvas {
                        PaneDivider(title: "Inspector width", vertical: true, direction: -1,
                                    value: Binding(get: { fitted.inspector }, set: { sizes.inspector = $0 }),
                                    limits: 240...min(360, max(240, geometry.size.width - fitted.navigator - 428)))
                        InspectorView(model: model).frame(width: fitted.inspector)
                    }
                }
                .frame(maxHeight: .infinity)
                if !model.focusesCanvas {
                    PaneDivider(title: "Timeline height", vertical: false, direction: -1,
                                value: Binding(get: { fitted.timeline }, set: { sizes.timeline = $0 }),
                                limits: 170...min(420, max(170, geometry.size.height - 364)))
                    TimelinePanel(model: model).frame(height: fitted.timeline)
                }
            }
        }
        .onChange(of: model.isPlaying) { revealPlaybackControls() }
        .onChange(of: model.focusesCanvas) { revealPlaybackControls() }
        .onChange(of: playbackControlsHeld) { revealPlaybackControls() }
    }

    /// Like typical video controls: pointer movement shows the focus playback bar,
    /// and it fades with the cursor after a short idle while playing.
    private func revealPlaybackControls() {
        hideControlsTask?.cancel()
        if !showsPlaybackControls { withAnimation(.easeOut(duration: 0.15)) { showsPlaybackControls = true } }
        guard model.focusesCanvas, model.isPlaying, !playbackControlsHeld else { return }
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, model.isPlaying, !playbackControlsHeld else { return }
            withAnimation(.easeOut(duration: 0.3)) { showsPlaybackControls = false }
            if pointerOverCanvas { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }
}

/// A draggable, accessible gap between floating panels. It shows a small
/// grabber only while the pointer is over it or it is being dragged.
private struct PaneDivider: View {
    var title: String
    var vertical: Bool
    var direction: CGFloat = 1
    @Binding var value: CGFloat
    var limits: ClosedRange<CGFloat>
    @State private var dragStart: CGFloat?
    @State private var hovering = false

    private func set(_ proposed: CGFloat) { value = min(max(proposed, limits.lowerBound), limits.upperBound) }

    var body: some View {
        Capsule().fill(Color.fwAccent.opacity(hovering || dragStart != nil ? 0.7 : 0))
            .frame(width: vertical ? 3 : 36, height: vertical ? 36 : 3)
            .frame(width: vertical ? EditorPaneSizes.divider : nil, height: vertical ? nil : EditorPaneSizes.divider)
            .frame(maxWidth: vertical ? nil : .infinity, maxHeight: vertical ? .infinity : nil)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { gesture in
                    if dragStart == nil { dragStart = value }
                    let delta = vertical ? gesture.translation.width : gesture.translation.height
                    set((dragStart ?? value) + direction * delta)
                }
                .onEnded { _ in
                    dragStart = nil
                    if !hovering { NSCursor.arrow.set() }
                })
            .onHover { inside in
                hovering = inside
                // Mid-drag the pointer can outrun the thin strip; keep the resize cursor until release.
                guard dragStart == nil else { return }
                (inside ? (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown) : NSCursor.arrow).set()
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
