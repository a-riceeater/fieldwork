import AppKit
import SwiftUI
import DrillTiming
import DrillCore
import DrillMedia

struct TimelineMarker: Equatable {
    var time: Double
    var label: String
}

struct TimelineSetMarker: Equatable {
    var id: SetID
    var label: String
    var time: Double
    var selected: Bool
}

struct TimelineAnchorMarker: Equatable {
    var id: AnchorID
    var time: Double
    var label: String
}

struct TimelineState: Equatable {
    var duration: Double
    var playhead: Double
    var measures: [TimelineMarker]
    var beats: [Double]
    var sets: [TimelineSetMarker]
    var anchors: [TimelineAnchorMarker]
    var sampleRate: Double
    var peaksFrameCount: Int64
}

@MainActor
protocol TimelineDelegate: AnyObject {
    func timelineSeek(_ seconds: Double)
    func timelineSelectSet(_ id: SetID)
    func timelineMoveAnchor(_ id: AnchorID, to seconds: Double)
    func timelineRemoveAnchor(_ id: AnchorID)
    func timelineTogglePlay()
}

/// Lanes, top to bottom: seconds ruler, measures ruler, waveform, sync anchors,
/// set arrivals. One playhead crosses every lane. Drawing reads cached peaks
/// for the visible range only.
final class TimelineCanvasView: NSView {
    weak var delegate: TimelineDelegate?
    var peaks: WaveformPeaks? { didSet { needsDisplay = true } }
    var state: TimelineState? {
        didSet {
            guard state != oldValue else { return }
            if let state, oldValue == nil || oldValue?.duration != state.duration { fitAll() }
            keepPlayheadVisible()
            needsDisplay = true
            setAccessibilityValue(state.map { "Playhead \(TimeFormat.clock($0.playhead))" } ?? "")
        }
    }

    private var visibleStart: Double = -1
    private var secondsPerPoint: Double = 0.05
    private var draggingAnchor: (id: AnchorID, time: Double)?
    private var scrubbing = false

    private let secondsLane: CGFloat = 18, measuresLane: CGFloat = 18, anchorsLane: CGFloat = 20, setsLane: CGFloat = 28

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Timeline")
        setAccessibilityIdentifier("timeline.lanes")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var waveformRect: CGRect {
        CGRect(x: 0, y: secondsLane + measuresLane, width: bounds.width, height: max(20, bounds.height - secondsLane - measuresLane - anchorsLane - setsLane))
    }
    private var anchorsRect: CGRect { CGRect(x: 0, y: waveformRect.maxY, width: bounds.width, height: anchorsLane) }
    private var setsRect: CGRect { CGRect(x: 0, y: anchorsRect.maxY, width: bounds.width, height: setsLane) }

    func x(_ t: Double) -> CGFloat { CGFloat((t - visibleStart) / secondsPerPoint) }
    func time(_ x: CGFloat) -> Double { visibleStart + Double(x) * secondsPerPoint }

    func fitAll() {
        guard let state, bounds.width > 10 else { return }
        visibleStart = -1
        secondsPerPoint = (state.duration + 2) / Double(bounds.width)
    }

    func zoom(by factor: Double, at px: CGFloat) {
        let anchor = time(px)
        secondsPerPoint = min(max(secondsPerPoint / factor, 0.0005), 2)
        visibleStart = anchor - Double(px) * secondsPerPoint
        needsDisplay = true
    }

    private func keepPlayheadVisible() {
        guard let state, bounds.width > 0 else { return }
        let px = x(state.playhead)
        if px > bounds.width * 0.9 || px < 0 { visibleStart = state.playhead - Double(bounds.width) * 0.1 * secondsPerPoint }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let first = bounds.width < 10
        super.setFrameSize(newSize)
        if first { fitAll() }
    }

    // MARK: Interaction

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 49,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
            return super.keyDown(with: event)
        }
        if !event.isARepeat { delegate?.timelineTogglePlay() }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode != 49 { super.keyUp(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let state else { return }
        let p = convert(event.locationInWindow, from: nil)
        if setsRect.contains(p) {
            if let hit = state.sets.min(by: { abs(x($0.time) - p.x) < abs(x($1.time) - p.x) }), abs(x(hit.time) - p.x) < 10 {
                delegate?.timelineSelectSet(hit.id)
            }
            return
        }
        if anchorsRect.contains(p) {
            if let hit = state.anchors.min(by: { abs(x($0.time) - p.x) < abs(x($1.time) - p.x) }), abs(x(hit.time) - p.x) < 8 {
                if event.modifierFlags.contains(.control) || event.type == .rightMouseDown {
                    showAnchorMenu(hit, at: p)
                } else {
                    draggingAnchor = (hit.id, hit.time)
                }
            }
            return
        }
        scrubbing = true
        delegate?.timelineSeek(time(p.x))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let state else { return }
        let p = convert(event.locationInWindow, from: nil)
        if anchorsRect.contains(p), let hit = state.anchors.min(by: { abs(x($0.time) - p.x) < abs(x($1.time) - p.x) }), abs(x(hit.time) - p.x) < 8 {
            showAnchorMenu(hit, at: p)
        }
    }

    private func showAnchorMenu(_ anchor: TimelineAnchorMarker, at p: CGPoint) {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Remove Anchor \(anchor.label)", action: #selector(removeAnchorFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = anchor.id.description
        menu.addItem(item)
        menu.popUp(positioning: nil, at: p, in: self)
    }

    @objc private func removeAnchorFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = AnchorID(raw) else { return }
        delegate?.timelineRemoveAnchor(id)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let anchor = draggingAnchor {
            draggingAnchor = (anchor.id, max(0, time(p.x)))
            needsDisplay = true
        } else if scrubbing {
            delegate?.timelineSeek(time(p.x))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let anchor = draggingAnchor, let original = state?.anchors.first(where: { $0.id == anchor.id }), abs(original.time - anchor.time) > 1e-4 {
            delegate?.timelineMoveAnchor(anchor.id, to: anchor.time)
        }
        draggingAnchor = nil
        scrubbing = false
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            zoom(by: exp(event.scrollingDeltaY * 0.01), at: p.x)
        } else {
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            visibleStart -= Double(delta) * secondsPerPoint * (event.hasPreciseScrollingDeltas ? 1 : 10)
            needsDisplay = true
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil).x)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Tokens.surface.setFill()
        bounds.fill()
        guard let state else { return }
        let secondary = Tokens.textSecondary
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let monoBold = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

        // Lane backgrounds and separators.
        NSColor(hex: 0x0F1820).setFill()
        waveformRect.fill()
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1)
        for y in [secondsLane, secondsLane + measuresLane, anchorsRect.minY, setsRect.minY] {
            ctx.strokeLineSegments(between: [CGPoint(x: 0, y: y), CGPoint(x: bounds.width, y: y)])
        }

        // Seconds ruler.
        let candidates: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60]
        let stepSeconds = candidates.first { $0 / secondsPerPoint >= 60 } ?? 120
        var t = (time(0) / stepSeconds).rounded(.down) * stepSeconds
        while x(t) < bounds.width {
            let px = x(t)
            ctx.setStrokeColor(secondary.withAlphaComponent(0.5).cgColor)
            ctx.strokeLineSegments(between: [CGPoint(x: px, y: secondsLane - 6), CGPoint(x: px, y: secondsLane)])
            NSAttributedString(string: TimeFormat.clock(t), attributes: [.font: mono, .foregroundColor: secondary]).draw(at: CGPoint(x: px + 3, y: 2))
            t += stepSeconds
        }

        // Measures ruler with beat ticks when there is room.
        let beatSpacing = state.beats.count > 1 ? Double(x(state.beats[1]) - x(state.beats[0])) : 0
        if beatSpacing > 5 {
            ctx.setStrokeColor(secondary.withAlphaComponent(0.35).cgColor)
            for b in state.beats where x(b) >= 0 && x(b) <= bounds.width {
                ctx.strokeLineSegments(between: [CGPoint(x: x(b), y: secondsLane + measuresLane - 4), CGPoint(x: x(b), y: secondsLane + measuresLane)])
            }
        }
        var lastLabelX: CGFloat = -100
        for m in state.measures where x(m.time) >= -40 && x(m.time) <= bounds.width {
            let px = x(m.time)
            ctx.setStrokeColor(secondary.withAlphaComponent(0.7).cgColor)
            ctx.strokeLineSegments(between: [CGPoint(x: px, y: secondsLane), CGPoint(x: px, y: secondsLane + measuresLane)])
            ctx.setStrokeColor(Tokens.grid.withAlphaComponent(0.25).cgColor)
            ctx.strokeLineSegments(between: [CGPoint(x: px, y: waveformRect.minY), CGPoint(x: px, y: waveformRect.maxY)])
            if px - lastLabelX > 28 {
                NSAttributedString(string: m.label, attributes: [.font: monoBold, .foregroundColor: Tokens.textPrimary]).draw(at: CGPoint(x: px + 3, y: secondsLane + 2))
                lastLabelX = px
            }
        }

        // Waveform from the peak cache (display gain only).
        if let peaks, state.sampleRate > 0 {
            let width = Int(bounds.width)
            let startFrame = Int64(max(0, time(0)) * state.sampleRate)
            let endFrame = Int64(max(0, time(bounds.width)) * state.sampleRate)
            if endFrame > startFrame {
                let offsetX = max(0, x(0)) // when visibleStart < 0, audio starts to the right
                let pixelWidth = max(1, width - Int(offsetX))
                let columns = peaks.peaks(frames: startFrame..<endFrame, buckets: pixelWidth)
                let mid = waveformRect.midY, half = waveformRect.height / 2 - 4
                ctx.setStrokeColor(Tokens.fieldAccent.withAlphaComponent(0.75).cgColor)
                ctx.setLineWidth(1)
                for (i, c) in columns.enumerated() {
                    let px = offsetX + CGFloat(i) + 0.5
                    ctx.strokeLineSegments(between: [CGPoint(x: px, y: mid - CGFloat(c.max) * half), CGPoint(x: px, y: mid - CGFloat(c.min) * half)])
                }
            }
        } else {
            let text = state.peaksFrameCount == 0 ? "No audio · counts only. Import WAV or MP3 to align music." : "Decoding waveform…"
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: secondary])
                .draw(at: CGPoint(x: 12, y: waveformRect.midY - 8))
        }

        // Anchors.
        for anchor in state.anchors {
            let time = draggingAnchor?.id == anchor.id ? draggingAnchor!.time : anchor.time
            let px = x(time)
            ctx.setStrokeColor(Tokens.accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeLineSegments(between: [CGPoint(x: px, y: waveformRect.minY), CGPoint(x: px, y: anchorsRect.maxY - 4)])
            let pin = CGRect(x: px - 5, y: anchorsRect.minY + 4, width: 10, height: 10)
            Tokens.accent.setFill()
            NSBezierPath(ovalIn: pin).fill()
            NSAttributedString(string: anchor.label, attributes: [.font: mono, .foregroundColor: Tokens.accent]).draw(at: CGPoint(x: px + 7, y: anchorsRect.minY + 3))
        }

        // Set arrivals and the move bars into them.
        var previousX: CGFloat?
        for set in state.sets {
            let px = x(set.time)
            if let previousX {
                let bar = CGRect(x: previousX + 2, y: setsRect.minY + 8, width: max(0, px - previousX - 4), height: 8)
                (set.selected ? Tokens.accent.withAlphaComponent(0.35) : secondary.withAlphaComponent(0.2)).setFill()
                NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
            }
            let diamond = NSBezierPath()
            diamond.move(to: CGPoint(x: px, y: setsRect.minY + 4))
            diamond.line(to: CGPoint(x: px + 6, y: setsRect.minY + 12))
            diamond.line(to: CGPoint(x: px, y: setsRect.minY + 20))
            diamond.line(to: CGPoint(x: px - 6, y: setsRect.minY + 12))
            diamond.close()
            (set.selected ? Tokens.accent : Tokens.textPrimary).setFill()
            diamond.fill()
            NSAttributedString(string: set.label, attributes: [.font: monoBold, .foregroundColor: set.selected ? Tokens.accent : Tokens.textPrimary])
                .draw(at: CGPoint(x: px + 8, y: setsRect.minY + 6))
            previousX = px
        }

        // Playhead across every lane.
        let ph = x(state.playhead)
        ctx.setStrokeColor(Tokens.error.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeLineSegments(between: [CGPoint(x: ph, y: 0), CGPoint(x: ph, y: bounds.height)])
    }
}

struct TimelineLanes: NSViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> TimelineCanvasView {
        let view = TimelineCanvasView(frame: .zero)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: TimelineCanvasView, context: Context) {
        view.state = model.timelineState()
        if view.peaks?.frameCount != model.peaks?.frameCount { view.peaks = model.peaks }
    }

    @MainActor
    final class Coordinator: NSObject, TimelineDelegate {
        let model: EditorModel
        init(model: EditorModel) { self.model = model }
        func timelineSeek(_ seconds: Double) { model.seek(to: seconds) }
        func timelineSelectSet(_ id: SetID) { model.selectSet(id) }
        func timelineMoveAnchor(_ id: AnchorID, to seconds: Double) { model.moveAnchor(id, toSeconds: seconds) }
        func timelineRemoveAnchor(_ id: AnchorID) { model.removeAnchor(id) }
        func timelineTogglePlay() { model.togglePlay() }
    }
}

extension EditorModel {
    func timelineState() -> TimelineState {
        let map = self.map
        var measures: [TimelineMarker] = []
        var beats: [Double] = []
        var sets: [TimelineSetMarker] = []
        var anchors: [TimelineAnchorMarker] = []
        if let map {
            let track = movement.timing
            let countsOnly = show.countingMode == .counts
            var seen = Set<MeasureID>()
            for event in track.events where event.kind == .beat {
                guard let t = try? map.audioTime(at: TimelineCursor(eventID: event.id)) else { continue }
                beats.append(t)
                if !countsOnly, seen.insert(event.measureID).inserted, let m = track.measures.first(where: { $0.id == event.measureID }) {
                    measures.append(TimelineMarker(time: t, label: "m\(m.number)"))
                }
            }
            if countsOnly {
                // Counts mode: a count ruler every 8 counts instead of measure numbers.
                var count = 0
                while Rational(count) <= map.totalPulses {
                    if let cursor = try? map.cursor(atPulse: Rational(count)), let t = try? map.audioTime(at: cursor) {
                        measures.append(TimelineMarker(time: t, label: "\(count)"))
                    }
                    count += 8
                }
            }
            for set in setsInMovement {
                if let t = try? map.audioTime(at: set.cursor) {
                    let label = set.rehearsalMark.isEmpty ? set.label : "\(set.label) · \(set.rehearsalMark)"
                    sets.append(TimelineSetMarker(id: set.id, label: label, time: t, selected: set.id == currentSetID))
                }
            }
            if let assetID = movement.audioAssetID {
                for anchor in track.anchors where anchor.assetID == assetID {
                    let label = (try? map.musicalPosition(at: anchor.cursor).label) ?? ""
                    anchors.append(TimelineAnchorMarker(id: anchor.id, time: anchor.seconds, label: label))
                }
            }
        }
        return TimelineState(duration: timelineDuration, playhead: playheadSeconds, measures: measures, beats: beats, sets: sets, anchors: anchors,
                             sampleRate: audioAsset?.sampleRate ?? 0, peaksFrameCount: hasAudio ? (peaks?.frameCount ?? -1) : 0)
    }
}
