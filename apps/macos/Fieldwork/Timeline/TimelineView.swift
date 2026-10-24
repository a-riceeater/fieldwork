import AppKit
import SwiftUI
import Combine
import QuartzCore
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
            var previousContent = oldValue
            previousContent?.playhead = state?.playhead ?? 0
            if previousContent != state { needsDisplay = true }
            if let state, oldValue == nil || oldValue?.duration != state.duration { fitAll() }
            keepPlayheadVisible()
            updatePlayheadLayer()
            setAccessibilityValue(state.map { "Playhead \(TimeFormat.clock($0.playhead))" } ?? "")
        }
    }

    private let playheadLayer = CALayer()
    private var visibleStart: Double = -1 {
        didSet { needsDisplay = true; updatePlayheadLayer() }
    }
    private var secondsPerPoint: Double = 0.05 {
        didSet { needsDisplay = true; updatePlayheadLayer() }
    }
    private var draggingAnchor: (id: AnchorID, time: Double)?
    private var scrubbing = false

    static let secondsLane: CGFloat = 18, measuresLane: CGFloat = 18, anchorsLane: CGFloat = 18, setsLane: CGFloat = 26
    /// Height of the lanes above and below the waveform, for overlays placed on it.
    static let aboveWaveform = secondsLane + measuresLane, belowWaveform = anchorsLane + setsLane
    private var secondsLane: CGFloat { Self.secondsLane }
    private var measuresLane: CGFloat { Self.measuresLane }
    private var anchorsLane: CGFloat { Self.anchorsLane }
    private var setsLane: CGFloat { Self.setsLane }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Timeline")
        setAccessibilityIdentifier("timeline.lanes")
        wantsLayer = true
        playheadLayer.name = "timeline.playhead"
        layer?.addSublayer(playheadLayer)
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
        let range = navigationRange(for: state)
        visibleStart = range.lowerBound
        secondsPerPoint = (range.upperBound - range.lowerBound) / Double(bounds.width)
    }

    func zoom(by factor: Double, at px: CGFloat) {
        guard factor.isFinite, factor > 0 else { return }
        let anchor = time(px)
        secondsPerPoint = max(secondsPerPoint / factor, 0.0005)
        visibleStart = anchor - Double(px) * secondsPerPoint
        constrainViewport()
        needsDisplay = true
    }

    /// Include authored pre-roll and leave one second of breathing room at each end.
    private func navigationRange(for state: TimelineState) -> ClosedRange<Double> {
        let markers = state.beats + state.sets.map(\.time) + state.anchors.map(\.time)
        return (min(0, markers.min() ?? 0) - 1)...(max(state.duration, markers.max() ?? 0) + 1)
    }

    private func constrainViewport() {
        guard let state, bounds.width > 10 else { return }
        let range = navigationRange(for: state)
        let maximumScale = (range.upperBound - range.lowerBound) / Double(bounds.width)
        secondsPerPoint = min(secondsPerPoint, maximumScale)
        let latestStart = max(range.lowerBound, range.upperBound - Double(bounds.width) * secondsPerPoint)
        visibleStart = min(max(visibleStart, range.lowerBound), latestStart)
    }

    private func keepPlayheadVisible() {
        guard let state, bounds.width > 0 else { return }
        let px = x(state.playhead)
        if px > bounds.width * 0.9 || px < 0 {
            visibleStart = state.playhead - Double(bounds.width) * 0.1 * secondsPerPoint
            constrainViewport()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let wasFitted = bounds.width < 10 || state.map {
            let range = navigationRange(for: $0)
            return Double(bounds.width) * secondsPerPoint >= range.upperBound - range.lowerBound - 1e-6
        } == true
        super.setFrameSize(newSize)
        if wasFitted { fitAll() } else { constrainViewport() }
        updatePlayheadLayer()
    }

    /// Composite one thin layer while the waveform, rulers and markers stay unchanged.
    private func updatePlayheadLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playheadLayer.isHidden = state == nil
        playheadLayer.backgroundColor = Tokens.error.cgColor
        playheadLayer.frame = CGRect(x: x(state?.playhead ?? 0) - 0.75, y: 0, width: 1.5, height: bounds.height)
        CATransaction.commit()
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
            constrainViewport()
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
        Tokens.dynamic(light: 0xEEF1F5, dark: 0x0F1820).setFill()
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
            NSAttributedString(string: Self.rulerTime(t, step: stepSeconds), attributes: [.font: mono, .foregroundColor: secondary]).draw(at: CGPoint(x: px + 3, y: 2))
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
        var labelEnd: CGFloat = -.infinity
        for m in state.measures where x(m.time) >= -40 && x(m.time) <= bounds.width {
            let px = x(m.time)
            ctx.setStrokeColor(secondary.withAlphaComponent(0.7).cgColor)
            ctx.strokeLineSegments(between: [CGPoint(x: px, y: secondsLane), CGPoint(x: px, y: secondsLane + measuresLane)])
            ctx.setStrokeColor(Tokens.grid.withAlphaComponent(0.25).cgColor)
            ctx.strokeLineSegments(between: [CGPoint(x: px, y: waveformRect.minY), CGPoint(x: px, y: waveformRect.maxY)])
            let label = NSAttributedString(string: m.label, attributes: [.font: monoBold, .foregroundColor: Tokens.textPrimary])
            if px + 3 > labelEnd + 8 {
                label.draw(at: CGPoint(x: px + 3, y: secondsLane + 2))
                labelEnd = px + 3 + label.size().width
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
                ctx.setStrokeColor(Tokens.dynamic(light: 0x2BA3A6, dark: 0x5DD2D4).withAlphaComponent(0.75).cgColor)
                ctx.setLineWidth(1)
                for (i, c) in columns.enumerated() {
                    let px = offsetX + CGFloat(i) + 0.5
                    ctx.strokeLineSegments(between: [CGPoint(x: px, y: mid - CGFloat(c.max) * half), CGPoint(x: px, y: mid - CGFloat(c.min) * half)])
                }
            }
        } else if state.peaksFrameCount != 0 {
            // Without audio the panel overlays its own empty state on this lane.
            NSAttributedString(string: "Decoding waveform…", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: secondary])
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

        // Set arrivals and the move bars into them. Markers shrink when sets are
        // close together, and labels that would collide are left out (the
        // selected set's label always shows), so dense shows stay readable.
        let setXs = state.sets.map { x($0.time) }
        let midY = setsRect.minY + 10
        for (i, set) in state.sets.enumerated() {
            let px = setXs[i]
            guard i > 0 else { continue }
            let previousX = setXs[i - 1]
            guard px >= 0, previousX <= bounds.width, px - previousX > 6 else { continue }
            let bar = CGRect(x: previousX + 3, y: midY - 2, width: px - previousX - 6, height: 4)
            (set.selected ? Tokens.accent.withAlphaComponent(0.45) : secondary.withAlphaComponent(0.22)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        }
        for (i, set) in state.sets.enumerated() where setXs[i] >= -8 && setXs[i] <= bounds.width + 8 {
            let px = setXs[i]
            let gap = min(i > 0 ? px - setXs[i - 1] : .infinity, i + 1 < setXs.count ? setXs[i + 1] - px : .infinity)
            let half: CGFloat = set.selected ? 6 : (gap >= 16 ? 5 : (gap >= 8 ? 3.5 : 0))
            let color = set.selected ? Tokens.accent : Tokens.textPrimary
            if half > 0 {
                let diamond = NSBezierPath()
                diamond.move(to: CGPoint(x: px, y: midY - half))
                diamond.line(to: CGPoint(x: px + half, y: midY))
                diamond.line(to: CGPoint(x: px, y: midY + half))
                diamond.line(to: CGPoint(x: px - half, y: midY))
                diamond.close()
                color.setFill()
                diamond.fill()
            } else {
                color.withAlphaComponent(0.6).setStroke()
                let tick = NSBezierPath()
                tick.move(to: CGPoint(x: px, y: midY - 4))
                tick.line(to: CGPoint(x: px, y: midY + 4))
                tick.lineWidth = 1
                tick.stroke()
            }
        }
        var taken: [ClosedRange<CGFloat>] = []
        func label(_ index: Int) -> (NSAttributedString, CGRect) {
            let set = state.sets[index]
            let text = NSAttributedString(string: set.label, attributes: [
                .font: set.selected ? monoBold : mono,
                .foregroundColor: set.selected ? Tokens.accent : Tokens.textPrimary.withAlphaComponent(0.85),
            ])
            let size = text.size()
            return (text, CGRect(x: setXs[index] + 8, y: midY - size.height / 2, width: size.width, height: size.height))
        }
        if let selected = state.sets.firstIndex(where: \.selected) {
            let (text, rect) = label(selected)
            Tokens.surface.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: 0), xRadius: 3, yRadius: 3).fill()
            text.draw(at: rect.origin)
            taken.append(rect.minX - 6...rect.maxX + 6)
        }
        for i in state.sets.indices where !state.sets[i].selected && setXs[i] >= -40 && setXs[i] <= bounds.width {
            let (text, rect) = label(i)
            // A label must end before the next marker and clear every label already drawn.
            let nextX = i + 1 < setXs.count ? setXs[i + 1] : .infinity
            guard rect.maxX + 4 < nextX, !taken.contains(where: { $0.overlaps(rect.minX - 6...rect.maxX + 6) }) else { continue }
            text.draw(at: rect.origin)
            taken.append(rect.minX...rect.maxX)
        }

        // The playhead is composited separately, without rerasterizing these lanes.
    }

    /// Ruler labels as short as the step allows: "1:30" rather than "01:30.000".
    static func rulerTime(_ t: Double, step: Double) -> String {
        guard step >= 1 else { return TimeFormat.clock(t) }
        let whole = Int(abs(t).rounded())
        return "\(t < 0 ? "-" : "")\(whole / 60):\(String(format: "%02d", whole % 60))"
    }
}

struct TimelineLanes: NSViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> TimelineCanvasView {
        let view = TimelineCanvasView(frame: .zero)
        view.delegate = context.coordinator
        context.coordinator.connect(view)
        return view
    }

    func updateNSView(_ view: TimelineCanvasView, context: Context) {
        view.state = model.timelineState()
        if view.peaks?.frameCount != model.peaks?.frameCount { view.peaks = model.peaks }
    }

    @MainActor
    final class Coordinator: NSObject, TimelineDelegate {
        let model: EditorModel
        private var frames: AnyCancellable?
        init(model: EditorModel) { self.model = model }
        func connect(_ view: TimelineCanvasView) {
            frames = model.playbackPosition.frames.sink { [weak self, weak view] seconds in
                guard self?.model.isPlaying == true else { return }
                view?.state?.playhead = seconds
            }
        }
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
