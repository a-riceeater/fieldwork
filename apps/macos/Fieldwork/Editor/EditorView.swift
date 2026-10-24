import SwiftUI
import DrillTiming
import DrillCore
import FieldworkTour

/// Main editor layout: navigator | canvas | inspector over a resizable timeline,
/// with a status bar. The SwiftUI toolbar is bridged into the NSWindow toolbar,
/// which receives system Liquid Glass on macOS 26.
struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.recoveredBanner ?? model.readOnlyReason {
                BannerView(text: banner, isWarning: model.readOnlyReason != nil) { model.recoveredBanner = nil }
            }
            if model.isArranging {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Arranging performers…")
                    Spacer()
                    Button("Cancel") { model.cancelArrangement() }
                }
                .padding(.horizontal, Tokens.Space.l)
                .padding(.vertical, Tokens.Space.s)
                .background(.bar)
            }
            EditorWorkspace(model: model)
            if !model.focusesCanvas { StatusBar(model: model) }
        }
        .background(Color.fwWindow)
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            CoachMarkOverlay(model: model, anchors: anchors)
        }
        .toolbar { toolbarContent }
        .sheet(item: $model.conflict) { pending in ConflictSheet(pending: pending) }
        .sheet(isPresented: $model.showExport) { ExportSheet(model: model) }
        .sheet(isPresented: $model.showAddSection) { AddSectionSheet(model: model) }
        .sheet(isPresented: $model.showProjectSettings) { ProjectSettingsSheet(model: model) }
        .sheet(item: $model.importReport) { report in
            ImportReportSheet(report: report) { model.alignOpeningSet(atSeconds: $0) }
        }
        .confirmationDialog("Leave Draw Next Set?", isPresented: $model.showsDraftExitConfirmation, titleVisibility: .visible) {
            Button("Discard Drawing and Leave", role: .destructive) { model.confirmDraftExit() }
            Button("Keep Drawing", role: .cancel) { model.cancelDraftExit() }
        } message: {
            Text("Your drawing has changes that haven't been applied with Auto Route. Leaving discards those changes. Performers already placed by Auto Route will stay where they are.")
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }
}

/// Floating cluster over the canvas: focus/fit/zoom. Uses glass, never the field itself.
struct CanvasToolCluster: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 2) {
            Button { model.focusesCanvas.toggle() } label: {
                Image(systemName: model.focusesCanvas ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .help(model.focusesCanvas ? "Show Panels (⇧⌘F)" : "Hide Panels (⇧⌘F)")
            .accessibilityLabel(model.focusesCanvas ? "Show panels" : "Hide panels")
            Button { model.requestCanvas(.fitSelection) } label: { Image(systemName: "scope") }
                .help("Fit Selection")
                .accessibilityLabel("Fit selection")
            Button { model.requestCanvas(.zoomOut) } label: { Image(systemName: "minus.magnifyingglass") }
                .accessibilityLabel("Zoom out")
            Button { model.requestCanvas(.zoomIn) } label: { Image(systemName: "plus.magnifyingglass") }
                .accessibilityLabel("Zoom in")
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .padding(.horizontal, Tokens.Space.m)
        .padding(.vertical, Tokens.Space.s)
        .floatingGlass()
        .glassGroup()
    }
}

/// Floating transport shown in canvas focus, where the timeline is hidden:
/// play/pause, a scrubbable progress bar and the clock. Uses glass like the tool cluster.
struct FocusPlaybackBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var position: PlaybackPosition
    /// Set while hovered or scrubbed, so the auto-hide leaves the bar up.
    @Binding var isHeld: Bool
    /// Follows every display frame so the bar moves smoothly; the readout is throttled.
    @State private var seconds: Double = 0
    @State private var scrubbing = false
    @State private var hovering = false

    var body: some View {
        let duration = model.timelineDuration
        HStack(spacing: Tokens.Space.m) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            GeometryReader { geometry in
                let progress = min(max(seconds / duration, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.15))
                    Capsule().fill(Color.fwAccent)
                        .frame(width: geometry.size.width * progress)
                    Circle().fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                        .frame(width: scrubbing ? 14 : 10, height: scrubbing ? 14 : 10)
                        .offset(x: geometry.size.width * progress - (scrubbing ? 7 : 5))
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        scrubbing = true
                        let fraction = min(max(gesture.location.x / max(geometry.size.width, 1), 0), 1)
                        model.seek(to: fraction * duration)
                    }
                    .onEnded { _ in scrubbing = false })
                .animation(.easeOut(duration: 0.12), value: scrubbing)
            }
            .frame(height: 18)
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue(TimeFormat.clock(position.readoutSeconds))
            .accessibilityAdjustableAction { adjustment in
                switch adjustment {
                case .increment: model.seek(to: min(seconds + 5, duration))
                case .decrement: model.seek(to: max(seconds - 5, 0))
                @unknown default: break
                }
            }
            Text("\(TimeFormat.clock(max(position.readoutSeconds, 0))) / \(TimeFormat.clock(duration))")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Color.fwSecondary)
                .fixedSize()
        }
        .controlSize(.large)
        .padding(.horizontal, Tokens.Space.l)
        .padding(.vertical, Tokens.Space.s)
        .frame(maxWidth: 520)
        .floatingGlass()
        .onHover { hovering = $0 }
        .onChange(of: hovering || scrubbing) { _, held in isHeld = held }
        .onAppear { seconds = position.seconds }
        .onDisappear { isHeld = false }
        .onReceive(position.frames) { seconds = $0 }
    }
}

struct BannerView: View {
    var text: String
    var isWarning: Bool
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Space.s) {
            Image(systemName: isWarning ? "lock.fill" : "arrow.counterclockwise.circle.fill")
            Text(text).font(.callout)
            Spacer()
            if !isWarning { Button("Dismiss", action: dismiss).buttonStyle(.borderless) }
        }
        .padding(.horizontal, Tokens.Space.l)
        .padding(.vertical, Tokens.Space.s)
        .foregroundStyle(isWarning ? Color.fwWarning : Color.primary)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}

struct StatusBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let issues = model.analysisIssues
        HStack(spacing: Tokens.Space.l) {
            Text(model.currentSet.map { "Set \($0.label)" } ?? "")
                .font(.system(size: 11, weight: .semibold))
            StatusPlaybackReadout(model: model, position: model.playbackPosition)
            Text("\(model.selection.count) selected")
            if let message = model.statusMessage {
                Text(message).lineLimit(1).truncationMode(.tail).foregroundStyle(Color.fwSecondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Spacer()
            if model.hasAudio {
                Label(model.audioStatus, systemImage: "waveform")
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(Color.fwSecondary)
            }
            if !issues.isEmpty {
                Label("\(issues.count) warning\(issues.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.fwWarning)
            }
            Text(model.document?.saveStateText ?? "")
                .foregroundStyle(Color.fwSecondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, Tokens.Space.m + Tokens.Layout.panelInset)
        .frame(height: Tokens.Layout.status)
        .padding(.bottom, 2)
    }
}

/// Sheet offering the explicit resolutions for a timing conflict.
struct ConflictSheet: View {
    let pending: PendingConflict

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Label("Timing conflict", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Color.fwWarning)
            Text(pending.conflict.message)
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing has changed yet. Choose how to proceed:")
                .foregroundStyle(Color.fwSecondary)
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                ForEach(Array(pending.conflict.options.enumerated()), id: \.offset) { _, option in
                    Button(title(option)) { pending.resolve(option) }
                        .keyboardShortcut(option == .cancel ? .cancelAction : nil)
                }
            }
        }
        .padding(Tokens.Space.xl)
        .frame(width: 440)
    }

    func title(_ option: TimingResolution) -> String {
        switch option {
        case .replaceAnchor(let id): return "Replace pin \(pending.anchorLabels[id] ?? "")"
        case .releaseAnchor(let id): return "Release pin \(pending.anchorLabels[id] ?? "")"
        case .fitBetweenAnchors: return "Fit the interval between pins (keep both pins)"
        case .cancel: return "Cancel"
        }
    }
}

extension View {
    func tourAnchor(_ id: String) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [id: $0] }
    }
}

struct TourAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension EditorView {
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .help(model.undoName.map { "Undo \($0)" } ?? "Nothing to undo")
                .disabled(!model.canUndo)
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .help(model.redoName.map { "Redo \($0)" } ?? "Nothing to redo")
                .disabled(!model.canRedo)
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: Tokens.Space.s) {
                Picker("Tool", selection: $model.tool) {
                    ForEach(EditorTool.allCases) { tool in
                        Label(tool.title, systemImage: tool.symbol).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .help("Select (Option-Command-1), Line (Option-Command-2), Arc (Option-Command-3), Text (Option-Command-4). Select performers, then drag on the field with Line, Arc or Text. Curve (Option-Command-5): click start and end, click between to shape, drag points to adjust, Return to finish, Escape to cancel.")
                .tourAnchor("toolbar.forms")
                .accessibilityIdentifier("toolbar.forms")
                if model.tool == .text {
                    TextField("Text to spell", text: $model.shapeText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .help("Select performers, type the text, then drag on the field along the bottom of the letters")
                }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.snapEnabled) { Label("Snap", systemImage: "squareshape.split.3x3") }
                .help("Snap to \(TimeFormat.decimal(model.snapSteps, places: 2))-step grid. Hold Option while dragging to bypass.")
            Toggle(isOn: $model.circlesOnly) { Label("Circles", systemImage: "circle.grid.3x3.fill") }
                .help("Draw everyone as a circle in their section color (View › Draw Everyone as Circles)")
            Toggle(isOn: $model.alwaysShowLabels) { Label("Labels", systemImage: "tag") }
                .help("Always show small performer labels, even when zoomed out")
                .accessibilityLabel("Always show performer labels")
            Picker("Field", selection: $model.fieldStyle) {
                ForEach(FieldStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .help("Draw the field dark, as mowed grass or as graph paper (View › Field Style)")
            Picker("Axis", selection: $model.axisLock) {
                Text("Free").tag(AxisLock.none)
                Text("Side-to-side").tag(AxisLock.horizontal)
                Text("Front-to-back").tag(AxisLock.vertical)
            }
            .help("Axis lock for drags")
            Button { model.showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .help("Preview and export a coordinate PDF")
                .tourAnchor("toolbar.export")
                .accessibilityIdentifier("toolbar.export")
        }
    }
}

private struct StatusPlaybackReadout: View {
    let model: EditorModel
    @ObservedObject var position: PlaybackPosition

    var body: some View {
        let pulse = model.map?.locate(audioTime: position.readoutSeconds).pulse ?? 0
        Text(model.moveCountLabel(atPulse: pulse, places: 2)).monospacedDigit()
        Text(TimeFormat.clock(position.readoutSeconds)).monospacedDigit()
    }
}
