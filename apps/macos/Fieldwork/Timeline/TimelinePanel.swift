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
                Divider().frame(height: 22)
                PlaybackReadout(model: model, position: model.playbackPosition)
                Spacer()
                alignment
            }
            .padding(.horizontal, Tokens.Space.m)
            .padding(.vertical, Tokens.Space.s)
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
                    Button("Import Audio…") { importAudio() }
                        .accessibilityIdentifier("timeline.importAudio")
                    Button("Continue Without Music") { model.countsOnly() }
                        .help("Continue without music; playback follows the tempo map")
                } else {
                    Button("Replace Audio…") { importAudio() }
                        .help("Existing pins stay attached to their sample positions; review them after replacing")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, Tokens.Space.m)
            .padding(.vertical, Tokens.Space.xs)
        }
        .background(Color.fwSurface)
    }

    private var transport: some View {
        HStack(spacing: Tokens.Space.xs) {
            Button { model.stepSet(-1) } label: { Image(systemName: "backward.end.fill") }
                .help("Previous set").accessibilityLabel("Previous set")
            Button { model.togglePlay() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18) }
                .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                .tourAnchor("transport.play")
                .accessibilityIdentifier("transport.play")
            Button { model.stepSet(1) } label: { Image(systemName: "forward.end.fill") }
                .help("Next set").accessibilityLabel("Next set")
            Button { model.splitMoveAtPlayhead() } label: { Image(systemName: "scissors") }
                .help(model.playheadSplit.map { "Split this move at count \($0.count), adding a subset" }
                      ?? "Pause between two sets to split the move there")
                .accessibilityLabel("Split move at playhead")
                .disabled(model.playheadSplit == nil || model.readOnlyReason != nil)
            Picker("Rate", selection: $model.playbackRate) {
                Text("0.5×").tag(0.5)
                Text("0.75×").tag(0.75)
                Text("1×").tag(1.0)
            }
            .labelsHidden()
            .frame(width: 70)
            .help("Playback rate (does not change pins or timing)")
            Menu {
                Toggle("Whole Counts Only", isOn: $model.wholeCountsOnly)
                Text("Hide fractional counts and snap to the nearest count when pausing.")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Playback settings")
            .accessibilityLabel("Playback settings")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Tokens.Space.s)
        .padding(.vertical, Tokens.Space.xs)
        .floatingGlass(cornerRadius: 14)
    }

    private var alignment: some View {
        HStack(spacing: Tokens.Space.s) {
            Stepper("m\(alignMeasure)", value: $alignMeasure, in: 0...999).fixedSize()
            Stepper("b\(alignBeat)", value: $alignBeat, in: 1...16).fixedSize()
            Button("Align Here") { model.alignHere(measure: alignMeasure, beat: alignBeat) }
                .help("Pin measure \(alignMeasure) beat \(alignBeat) to the playhead's exact sample")
                .tourAnchor("timeline.alignHere")
                .accessibilityIdentifier("timeline.alignHere")
                .disabled(!model.hasAudio)
            Button("Align Set \(model.alignSet?.label ?? "") Here") { model.alignSelectedSetHere() }
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

    var body: some View {
        let map = model.map
        let location = map?.locate(audioTime: position.readoutSeconds)
        let musicalPosition = location.flatMap { try? map?.musicalPosition(at: $0.cursor) }
        let music = musicalPosition.map {
            model.wholeCountsOnly ? "m\($0.measureNumber) b\($0.beat)" : $0.label
        } ?? ""
        let pulse = location?.pulse ?? 0
        let count = model.wholeCountsOnly
            ? TimeFormat.decimal(floor(pulse + 1e-6), places: 0)
            : TimeFormat.decimal(pulse, places: 2)
        return HStack(spacing: Tokens.Space.m) {
            TextField("Time", text: $timeText)
                .frame(width: 92)
                .monospacedDigit()
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
            Text("count \(count)")
                .monospacedDigit()
                .foregroundStyle(Color.fwSecondary)
        }
        .font(.system(size: 12))
    }

}
