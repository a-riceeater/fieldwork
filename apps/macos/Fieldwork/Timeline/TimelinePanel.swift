import SwiftUI
import UniformTypeIdentifiers
import DrillTiming
import DrillCore

/// Transport, alignment controls and the timeline lanes.
struct TimelinePanel: View {
    @ObservedObject var model: EditorModel
    @State private var alignMeasure = 1
    @State private var alignBeat = 1
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Tokens.Space.m) {
                transport
                PlaybackReadout(model: model, position: model.playbackPosition)
                Spacer()
                alignment
            }
            .padding(.horizontal, Tokens.Space.s)
            .padding(.vertical, Tokens.Space.s)
            .glassGroup()
            TimelineLanes(model: model)
                .overlay {
                    if dropTargeted { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.fwAccent, lineWidth: 2) }
                }
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in model.importAudio(from: url) } }
                    }
                    return true
                }
                .tourAnchor("timeline.importAudio")
            HStack {
                Text(model.audioStatus).font(.system(size: 11)).foregroundStyle(Color.fwSecondary)
                Spacer()
                if !model.hasAudio {
                    Button { importAudio() } label: { Label("Import Audio…", systemImage: "waveform.badge.plus") }
                        .fwPrimaryButton()
                        .accessibilityIdentifier("timeline.importAudio")
                    Button("Continue Without Music") { model.countsOnly() }
                        .fwSecondaryButton()
                        .help("Continue without music; playback follows the tempo map")
                } else {
                    Button { importAudio() } label: { Label("Replace Audio…", systemImage: "waveform") }
                        .fwSecondaryButton()
                        .help("Existing pins stay attached to their sample positions; review them after replacing")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, Tokens.Space.m)
            .padding(.vertical, Tokens.Space.xs)
        }
        .fwPanel(material: false)
    }

    private struct Rate: Hashable { var value: Double; var title: String }
    private static let rates = [Rate(value: 0.5, title: "0.5×"), Rate(value: 0.75, title: "0.75×"), Rate(value: 1.0, title: "1×")]

    private var transport: some View {
        HStack(spacing: 2) {
            Button { model.stepSet(-1) } label: { Image(systemName: "backward.end.fill").frame(width: 24, height: 24) }
                .help("Previous set").accessibilityLabel("Previous set")
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.fwAccent))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            .tourAnchor("transport.play")
            .accessibilityIdentifier("transport.play")
            Button { model.stepSet(1) } label: { Image(systemName: "forward.end.fill").frame(width: 24, height: 24) }
                .help("Next set").accessibilityLabel("Next set")
            Button { model.splitMoveAtPlayhead() } label: { Image(systemName: "scissors").frame(width: 24, height: 24) }
                .help(model.playheadSplit.map { "Split this move at count \($0.count), adding a subset" }
                      ?? "Pause between two sets to split the move there")
                .accessibilityLabel("Split move at playhead")
                .disabled(model.playheadSplit == nil || model.readOnlyReason != nil)
            Menu {
                Picker("Playback Rate", selection: $model.playbackRate) {
                    ForEach(Self.rates, id: \.value) { Text($0.title).tag($0.value) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Whole Counts Only", isOn: $model.wholeCountsOnly)
                Text("Hide fractional counts and snap to the nearest count when pausing.")
            } label: {
                Text(Self.rates.first(where: { $0.value == model.playbackRate })?.title ?? "1×")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, Tokens.Space.xs)
            .help("Playback rate and settings (rate does not change pins or timing)")
            .accessibilityLabel("Playback rate and settings")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .floatingGlass(cornerRadius: Tokens.Radius.cluster)
    }

    private var alignment: some View {
        HStack(spacing: Tokens.Space.s) {
            HStack(spacing: Tokens.Space.xs) {
                MusicalPositionField(prefix: "m", name: "Measure", value: $alignMeasure, range: 0...999)
                MusicalPositionField(prefix: "b", name: "Beat", value: $alignBeat, range: 1...16)
            }
            Button { model.alignHere(measure: alignMeasure, beat: alignBeat) } label: { Label("Align Here", systemImage: "pin.fill") }
                .fwPrimaryButton()
                .help("Pin measure \(alignMeasure) beat \(alignBeat) to the playhead's exact sample")
                .tourAnchor("timeline.alignHere")
                .accessibilityIdentifier("timeline.alignHere")
                .disabled(!model.hasAudio)
            Button { model.alignSelectedSetHere() } label: { Label("Align Set \(model.alignSet?.label ?? "") Here", systemImage: "flag.fill") }
                .fwSecondaryButton()
                .help("Pin the arrival of the set you last chose to the playhead, wherever it is in the music")
                .disabled(!model.hasAudio)
        }
        .font(.system(size: 12))
    }

    private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .mp3]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a WAV or MP3 file. It will be copied into the show."
        if panel.runModal() == .OK, let url = panel.url { model.importAudio(from: url) }
    }
}

/// A small clock-dependent subtree; the rest of the editor observes document state only.
private struct PlaybackReadout: View {
    let model: EditorModel
    @ObservedObject var position: PlaybackPosition
    @State private var timeText = ""
    @FocusState private var editingTime: Bool

    var body: some View {
        let map = model.map
        let location = map?.locate(audioTime: position.readoutSeconds)
        let musicalPosition = location.flatMap { try? map?.musicalPosition(at: $0.cursor) }
        let music = musicalPosition.map {
            model.wholeCountsOnly ? "m\($0.measureNumber) b\($0.beat)" : $0.label
        } ?? ""
        let pulse = location?.pulse ?? 0
        return HStack(spacing: Tokens.Space.m) {
            TextField("Time", text: $timeText)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .focused($editingTime)
                .fwField(focused: editingTime)
                .frame(width: 96)
                .onSubmit {
                    if let t = TimeFormat.parseClock(timeText) { model.seek(to: t) }
                    timeText = TimeFormat.clock(position.readoutSeconds)
                }
                .onAppear { timeText = TimeFormat.clock(position.readoutSeconds) }
                .onChange(of: position.readoutSeconds) { _, t in timeText = TimeFormat.clock(t) }
                .help("Type a time such as 0:12.400 and press Return")
                .accessibilityLabel("Playhead time")
            Text(location?.isPreRoll == true ? "pre-roll" : music)
                .monospacedDigit()
                .frame(minWidth: 80, alignment: .leading)
            Text(model.moveCountLabel(atPulse: pulse, places: 2))
                .monospacedDigit()
                .foregroundStyle(Color.fwSecondary)
        }
        .font(.system(size: 12))
    }

}

/// A short typed musical position such as "m 17" or "b 3", clamped to its range.
private struct MusicalPositionField: View {
    var prefix: String
    var name: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text(prefix).foregroundStyle(Color.fwSecondary)
            TextField(name, value: $value, format: .number.grouping(.never))
                .monospacedDigit()
                .focused($focused)
                .frame(width: 30)
                .accessibilityLabel(name)
        }
        .fwField(focused: focused)
        .onChange(of: value) { _, newValue in
            let clamped = min(max(newValue, range.lowerBound), range.upperBound)
            if clamped != newValue { value = clamped }
        }
        .help("\(name) to pin. Type a number and press Return.")
    }
}
