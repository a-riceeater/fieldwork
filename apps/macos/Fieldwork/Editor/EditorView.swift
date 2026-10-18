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
            VSplitView {
                HSplitView {
                    NavigatorView(model: model)
                        .frame(minWidth: 180, idealWidth: Tokens.Layout.navigator, maxWidth: 320)
                    ZStack(alignment: .topLeading) {
                        FieldCanvas(model: model)
                            .tourAnchor("canvas.field")
                        CanvasToolCluster(model: model)
                            .padding(Tokens.Space.m)
                    }
                    .frame(minWidth: 420, maxWidth: .infinity)
                    InspectorView(model: model)
                        .frame(minWidth: 240, idealWidth: Tokens.Layout.inspector, maxWidth: 360)
                }
                .frame(minHeight: 360)
                TimelinePanel(model: model)
                    .frame(minHeight: 150, idealHeight: Tokens.Layout.timeline, maxHeight: 420)
            }
            StatusBar(model: model)
        }
        .background(Color.fwWindow)
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            CoachMarkOverlay(model: model, anchors: anchors)
        }
        .toolbar { EditorToolbar(model: model) }
        .sheet(item: $model.conflict) { pending in ConflictSheet(pending: pending) }
        .sheet(isPresented: $model.showExport) { ExportSheet(model: model) }
        .sheet(isPresented: $model.showAddSection) { AddSectionSheet(model: model) }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }
}

struct EditorToolbar: ToolbarContent {
    @ObservedObject var model: EditorModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .help(model.session.undoName.map { "Undo \($0)" } ?? "Nothing to undo")
                .disabled(!model.session.canUndo)
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .help(model.session.redoName.map { "Redo \($0)" } ?? "Nothing to redo")
                .disabled(!model.session.canRedo)
        }
        ToolbarItem(placement: .principal) {
            Picker("Tool", selection: $model.tool) {
                ForEach(EditorTool.allCases) { tool in
                    Label(tool.title, systemImage: tool.symbol).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .help("Select (V), Line (L), Arc (A). Select performers, then drag on the field with Line or Arc.")
            .tourAnchor("toolbar.forms")
            .accessibilityIdentifier("toolbar.forms")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.snapEnabled) { Label("Snap", systemImage: "squareshape.split.3x3") }
                .help("Snap to \(TimeFormat.decimal(model.snapSteps, places: 2))-step grid. Hold Option while dragging to bypass.")
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

/// Floating cluster over the canvas: fit/zoom. Uses glass, never the field itself.
struct CanvasToolCluster: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 2) {
            Button { model.requestCanvas(.fitField) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Fit Field (⌘0)")
                .accessibilityLabel("Fit field")
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
        .background(Color.fwSurface)
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
            Text("Count \(TimeFormat.decimal(model.currentPulse, places: 2))").monospacedDigit()
            Text(TimeFormat.clock(model.playheadSeconds)).monospacedDigit()
            Text("\(model.selection.count) selected")
            if let message = model.statusMessage {
                Text(message).lineLimit(1).truncationMode(.tail).foregroundStyle(Color.fwSecondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Spacer()
            if !issues.isEmpty {
                Label("\(issues.count) warning\(issues.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.fwWarning)
            }
            Text(model.document?.saveStateText ?? "")
                .foregroundStyle(Color.fwSecondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, Tokens.Space.m)
        .frame(height: Tokens.Layout.status)
        .background(Color.fwSurface)
        .overlay(alignment: .top) { Divider() }
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
