import AppKit
import SwiftUI
import DrillTiming
import DrillCore

enum CanvasViewCommand: Equatable {
    case fitField, fitSelection, zoomIn, zoomOut
}

/// The field editor surface: one NSView drawing every dot with Core Graphics
/// (no per-dot views). Pointer drags are previewed locally and committed as a
/// single semantic intent on mouse-up; Escape drops the preview.
final class FieldCanvasView: NSView {
    weak var delegate: FieldCanvasDelegate?

    var state: CanvasState? {
        didSet {
            guard state != oldValue else { return }
            if oldValue?.tool != state?.tool || oldValue?.draft?.tool != state?.draft?.tool
                || oldValue?.caption != state?.caption || state?.editable != true {
                curvePoints = []
                curveHistory = []
                curveHover = nil
                curveDragIndex = nil
            }
            updateCurveControls()
            if followsFieldFit, oldValue?.field != state?.field { fit(.fitField) }
            needsDisplay = true
            updateAccessibility()
        }
    }

    private(set) var transform = CanvasTransform()
    private var followsFieldFit = true

    private struct BackgroundKey: Equatable {
        var field: Field
        var style: FieldStyle
        var bounds: CGRect
        var transform: CanvasTransform
        var backingScale: CGFloat
    }
    /// One viewport-sized image. Panning, zooming, resizing or changing the field replaces it.
    private var backgroundCache: (key: BackgroundKey, image: CGImage)?
    struct LabelImage {
        var image: CGImage
        var size: CGSize
        var inkImage: CGImage
        var inkSize: CGSize

        func draw(at point: CGPoint, radius: CGFloat, placement: PerformerLabelPlacement, in ctx: CGContext) {
            let front = placement == .front
            let drawnSize = front ? inkSize : size
            let origin = placement.origin(at: point, radius: radius, size: drawnSize)
            ctx.draw(front ? inkImage : image, in: CGRect(origin: origin, size: drawnSize))
        }
    }
    private var labelCache: [String: LabelImage] = [:]
    private var labelBackingScale: CGFloat = 0
    private var labelFontSize: CGFloat = 0
    private var labelPaperStyle = false
    private var spaceDown = false
    /// Space toggles playback when tapped; Space-drag pans.
    private var spaceUsedForPan = false

    private enum Drag {
        case none
        case pan(start: CGPoint, center: Point2)
        /// `narrowTo` is set when the press landed on a dot inside a larger
        /// selection: releasing without dragging selects just that dot.
        case moveDots(ids: [PerformerID], anchor: Point2, start: Point2, delta: Point2, narrowTo: PerformerID?)
        case box(start: CGPoint, current: CGPoint, additive: Bool)
        case form(start: Point2, end: Point2, startView: CGPoint)
        case handle(form: CanvasForm, index: Int, start: Point2, geometry: FormGeometry)
        case moveNote(id: NoteID, start: Point2, delta: Point2)
        /// Dragging the waypoint at the end of segment `segment`.
        case waypoint(path: CanvasPath, segment: Int, point: Point2)
        /// Pulling a new waypoint out of a leg at a whole count; `moved` once the pointer leaves the press.
        case insertWaypoint(path: CanvasPath, count: Rational, point: Point2, moved: Bool)
        /// Bending leg `segment` by its midpoint handle; `sagitta` is the signed bulge in meters.
        case curve(path: CanvasPath, segment: Int, sagitta: Double)
        /// Drawing a Draw Next Set shape from the press to the pointer.
        case drawShape(start: Point2, end: Point2)
    }

    private var drag: Drag = .none
    private(set) var curvePoints: [Point2] = [] {
        didSet { updateCurveControls() }
    }
    private var curveHistory: [[Point2]] = []
    private var curveHover: Point2?
    private var curveDragIndex: Int?
    private var curveToolActive: Bool { state?.draft.map { $0.tool == .curve } ?? (state?.tool == .curve) }

    private var curveControlsWidth: NSLayoutConstraint?
    private(set) lazy var curveControls = NSHostingView(rootView: CurveControls(pointCount: 0, finish: {}, cancel: {}))

    private func updateCurveControls() {
        curveControls.isHidden = !curveToolActive || state?.editable != true
        curveControls.rootView = CurveControls(pointCount: curvePoints.count,
                                              finish: { [weak self] in self?.finishCurve() },
                                              cancel: { [weak self] in self?.cancelCurve() })
    }

    private func cancelCurve() {
        curvePoints = []
        curveHistory = []
        curveHover = nil
        curveDragIndex = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        curveHover = nil
        needsDisplay = true
    }

    private func finishCurve() {
        guard curvePoints.count >= 2 else {
            delegate?.canvasMessage("Place the start and end of the curve first.")
            return
        }
        let shape = DrawnShape.curve(points: curvePoints)
        do { try shape.validate() } catch {
            delegate?.canvasMessage(String(describing: error))
            return
        }
        if state?.draft != nil { delegate?.canvasCommitDraftShape(shape) }
        else { delegate?.canvasCommitForm(.curve(points: curvePoints)) }
        cancelCurve()
        if state?.draft != nil {
            delegate?.canvasMessage("Curve added. Choose Auto Route to fill the drawing, or start another shape.")
        }
    }

    /// Insert into the nearest span, keeping the first and last points as endpoints.
    static func curveInsertionIndex(_ point: Point2, in points: [Point2]) -> Int {
        guard points.count >= 2 else { return points.count }
        return (0..<(points.count - 1)).min { a, b in
            func distance(_ i: Int) -> Double {
                let start = points[i], delta = points[i + 1] - start
                let t = delta.dot(delta) > 0 ? min(1, max(0, (point - start).dot(delta) / delta.dot(delta))) : 0
                return point.distance(to: start + delta * t)
            }
            return distance(a) < distance(b)
        }! + 1
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityIdentifier("canvas.field")
        setAccessibilityLabel("Field")
        curveControls.translatesAutoresizingMaskIntoConstraints = false
        curveControls.isHidden = true
        addSubview(curveControls)
        let width = curveControls.widthAnchor.constraint(equalToConstant: max(0, min(640, frameRect.width - 24)))
        curveControlsWidth = width
        NSLayoutConstraint.activate([
            curveControls.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            curveControls.centerXAnchor.constraint(equalTo: centerXAnchor),
            width
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        // Size the overlay from the viewport, without constraining the viewport to the overlay.
        curveControlsWidth?.constant = max(0, min(640, newSize.width - 24))
        if resized, let state,
           followsFieldFit || transform.scale < CanvasTransform.fit(state.field.bounds, in: bounds).scale {
            fit(.fitField)
        }
    }

    // MARK: View commands

    func fit(_ command: CanvasViewCommand) {
        guard let state, bounds.width > 64, bounds.height > 64 else { return }
        switch command {
        case .fitField:
            transform = CanvasTransform.fit(state.field.bounds, in: bounds)
            followsFieldFit = true
        case .fitSelection:
            let points = state.dots.filter(\.selected).map(\.point)
            guard !points.isEmpty else { return fit(.fitField) }
            var rect = Rect2(points: points).insetBy(-4)
            if rect.width < 8 { rect = Rect2(minX: rect.center.x - 4, minY: rect.minY, maxX: rect.center.x + 4, maxY: rect.maxY) }
            if rect.height < 8 { rect = Rect2(minX: rect.minX, minY: rect.center.y - 4, maxX: rect.maxX, maxY: rect.center.y + 4) }
            followsFieldFit = false
            transform = CanvasTransform.fit(rect, in: bounds)
        case .zoomIn:
            zoom(by: 1.25, at: CGPoint(x: bounds.midX, y: bounds.midY))
        case .zoomOut:
            zoom(by: 0.8, at: CGPoint(x: bounds.midX, y: bounds.midY))
        }
        needsDisplay = true
    }

    /// The full-field overview is the furthest useful zoom-out. All zoom inputs
    /// share this limit, and reaching it restores the centered, resize-following fit.
    private func zoom(by factor: CGFloat, at anchor: CGPoint) {
        guard let state else { return }
        let fitted = CanvasTransform.fit(state.field.bounds, in: bounds)
        if factor < 1, transform.scale * factor <= fitted.scale {
            fit(.fitField)
            return
        }
        followsFieldFit = false
        transform.zoom(by: factor, at: anchor, in: bounds)
    }

    // MARK: Geometry helpers

    // A 0.25-meter radius is just under half a step, so one-step intervals keep a sliver of
    // daylight and forms keep the same proportions at every zoom, the full-field overview
    // included. The small floor only stops dots vanishing on very large fields.
    private var dotRadius: CGFloat { max(1.5, 0.25 * transform.scale) }

    private func view(_ p: Point2) -> CGPoint { transform.toView(p, in: bounds) }
    private func world(_ v: CGPoint) -> Point2 { transform.toWorld(v, in: bounds) }

    private func hitDot(at v: CGPoint) -> CanvasDot? {
        guard let state else { return nil }
        let limit = max(7.5, dotRadius + 4)
        var best: (CanvasDot, CGFloat)?
        for dot in state.dots {
            let p = view(dot.point)
            let d = hypot(p.x - v.x, p.y - v.y)
            if d <= limit, d < (best?.1 ?? .infinity) { best = (dot, d) }
        }
        return best?.0
    }

    private let handleRadius: CGFloat = 6

    /// Separate reshape grips from performer move targets at every zoom level.
    /// A leader joins each grip to the geometry point that it controls.
    func formHandlePositions(_ geometry: FormGeometry) -> [CGPoint] {
        geometry.handles.enumerated().map { index, anchor in
            let direction: Point2
            switch geometry {
            case .circle(let center, _):
                direction = index == 0 ? Point2(0, 1) : (anchor - center).normalized
            case .curve:
                let points = geometry.handles
                let before = points[max(0, index - 1)], after = points[min(points.count - 1, index + 1)]
                let normal = (after - before).perpendicular.normalized
                direction = normal.length > 0 ? normal : Point2(0, 1)
            case .line(let start, let end):
                let normal = (end - start).perpendicular.normalized
                direction = normal.length > 0 ? normal : Point2(0, 1)
            case .arc(_, _, let bulge):
                let t = index == 0 ? 0.0 : (index == 1 ? 1.0 : 0.5)
                let tangent = geometry.point(at: min(1, t + 0.001)) - geometry.point(at: max(0, t - 0.001))
                let normal = tangent.perpendicular.normalized * (bulge < 0 ? -1 : 1)
                direction = normal.length > 0 ? normal : Point2(0, 1)
            }
            let p = view(anchor)
            return CGPoint(x: p.x + CGFloat(direction.x) * 30, y: p.y + CGFloat(direction.y) * 30)
        }
    }

    private func hitHandle(at v: CGPoint) -> (CanvasForm, Int)? {
        // Performers always move. Only the separate square grips reshape.
        guard let state, state.editable, hitDot(at: v) == nil else { return nil }
        var best: (CanvasForm, Int, CGFloat)?
        for form in state.forms {
            for (index, p) in formHandlePositions(form.geometry).enumerated() {
                let distance = p.distance(to: v)
                if distance <= handleRadius + 3, distance < (best?.2 ?? .infinity) {
                    best = (form, index, distance)
                }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// A shown form whose outline passes under the pointer. Dragging the outline moves the whole form.
    private func hitFormOutline(at v: CGPoint) -> CanvasForm? {
        guard let state, state.editable else { return nil }
        return state.forms.first { form in
            let points = form.geometry.polyline().map(view)
            return zip(points, points.dropFirst()).contains { v.distance(toSegment: $0, $1) <= 5 }
        }
    }

    // MARK: Paths

    private enum PathHandle {
        case waypoint(Int)
        case curve(Int)
    }

    /// The one path whose handles are shown: a single selected performer on an editable set.
    private var editablePath: CanvasPath? {
        guard let state, state.editable, state.tool == .select else { return nil }
        return state.paths.first(where: \.editable)
    }

    private var pathHandleRadius: CGFloat { 6 }

    private func waypointPoints(_ path: CanvasPath) -> [(Int, Point2)] {
        let pieces = path.path.pieces(from: path.start)
        return Show.waypointSegments(path.segments).map { ($0, pieces[$0].end) }
    }

    /// Midpoints of the moving legs, where dragging bends the leg into an arc.
    private func curvePoints(_ path: CanvasPath) -> [(Int, Point2)] {
        path.path.pieces(from: path.start).filter { !$0.segment.isHold && $0.start.distance(to: $0.end) > 1e-6 }.map { ($0.index, $0.point(0.5)) }
    }

    private func hitPathHandle(at v: CGPoint) -> (CanvasPath, PathHandle)? {
        guard let path = editablePath else { return nil }
        let limit = pathHandleRadius + 3
        if let hit = waypointPoints(path).first(where: { view($0.1).distance(to: v) <= limit }) { return (path, .waypoint(hit.0)) }
        if let hit = curvePoints(path).first(where: { view($0.1).distance(to: v) <= limit }) { return (path, .curve(hit.0)) }
        return nil
    }

    /// A press on the editable path's line, with the nearest whole count inside the move.
    private func hitPathLine(at v: CGPoint) -> (CanvasPath, Rational)? {
        guard let path = editablePath, path.counts > Rational.one else { return nil }
        let points = polyline(path.path.pieces(from: path.start)).map(view)
        guard zip(points, points.dropFirst()).contains(where: { v.distance(toSegment: $0, $1) <= 5 }) else { return nil }
        let resolved = ResolvedPath(path.path, from: path.start)
        let last = Int(path.counts.doubleValue.rounded(.up)) - 1
        guard last >= 1 else { return nil }
        let nearest = (1...last).filter { Rational($0) < path.counts }.min { view(resolved.point(at: Double($0)).point).distance(to: v) < view(resolved.point(at: Double($1)).point).distance(to: v) }
        return nearest.map { (path, Rational($0)) }
    }

    /// Points along resolved pieces: line ends, and arcs sampled every few degrees.
    private func polyline(_ pieces: [PathPiece]) -> [Point2] {
        var points: [Point2] = pieces.first.map { [$0.start] } ?? []
        for piece in pieces {
            switch piece.segment {
            case .hold: continue
            case .line: points.append(piece.end)
            case .arc(_, _, let sweep):
                let n = max(8, Int(abs(sweep) / 4))
                for k in 1...n { points.append(piece.point(Double(k) / Double(n))) }
            }
        }
        return points
    }

    /// Segments as they look during a path drag, before anything commits.
    private func shownSegments(_ path: CanvasPath) -> [PathSegment] {
        switch drag {
        case .waypoint(let dragged, let i, let point) where dragged.id == path.id:
            var segments = path.segments
            segments[i] = segments[i].withEnd(point)
            return segments
        case .insertWaypoint(let dragged, let count, let point, true) where dragged.id == path.id:
            var (left, right, _) = path.path.split(at: count, from: path.start)
            guard let last = left.last, !last.isHold else { return path.segments }
            left[left.count - 1] = last.withEnd(point)
            return left + right
        case .curve(let dragged, let i, let sagitta) where dragged.id == path.id:
            let piece = path.path.pieces(from: path.start)[i]
            let chord = piece.start.distance(to: piece.end)
            var segments = path.segments
            segments[i] = abs(sagitta) <= curveSnap || chord <= 1e-6
                ? .line(counts: piece.counts, to: piece.end)
                : .arc(counts: piece.counts, to: piece.end, sweep: PerformerPath.sweep(chord: chord, sagitta: sagitta))
            return segments
        default:
            return path.segments
        }
    }

    /// Within this bulge a curved leg snaps back to straight (a quarter step), unless Option is held.
    private var curveSnap: Double { curveSnaps ? (state?.field.stepSize ?? 0.5715) / 4 : 0 }
    private var curveSnaps = true

    /// Signed bulge of `p` to the left of a leg's chord.
    private func sagitta(of p: Point2, path: CanvasPath, segment: Int) -> Double {
        let piece = path.path.pieces(from: path.start)[segment]
        let chord = piece.end - piece.start
        guard chord.length > 0 else { return 0 }
        return (p - piece.start.lerp(to: piece.end, 0.5)).dot(chord.perpendicular.normalized)
    }

    /// The shape a Draw Next Set drag makes: lines, arcs and text run from the press
    /// to the pointer, a block spans them as corners, and a circle is centered on the press.
    static func drawnShape(_ tool: DrawTool, from start: Point2, to end: Point2, text: String) -> DrawnShape {
        switch tool {
        case .curve: return .curve(points: [start, end])
        case .line: return .line(start: start, end: end)
        case .arc: return .arc(start: start, end: end, bulge: start.distance(to: end) * 0.25)
        case .block: return .block(start, end)
        case .circle: return .circle(center: start, radius: start.distance(to: end))
        case .text: return .text(TextShape(text.trimmingCharacters(in: .whitespacesAndNewlines), start: start, end: end))
        }
    }

    /// Strokes shape outlines; a one-point outline (the dot of "!") is a small filled dot.
    private func strokeOutlines(_ outlines: [[Point2]], in ctx: CGContext) {
        for outline in outlines {
            if outline.count == 1 {
                let c = view(outline[0])
                ctx.fillEllipse(in: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4))
            } else {
                ctx.addLines(between: outline.map(view))
            }
        }
        ctx.strokePath()
    }

    /// Starts dragging every member of a form, snapping on its first handle (a member position).
    private func beginFormMove(_ form: CanvasForm, at v: CGPoint) {
        delegate?.canvasSelect(form.members, additive: false)
        drag = .moveDots(ids: Array(form.members), anchor: form.geometry.handles[0], start: world(v), delta: .zero, narrowTo: nil)
    }

    // MARK: Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
    }

    /// Shows what a press will do: reshape on a square grip, move on a selected form.
    override func mouseMoved(with event: NSEvent) {
        guard case .none = drag, !spaceDown, let state, state.editable else { return }
        if curveToolActive {
            curveHover = curvePoints.isEmpty ? nil : snapped(world(convert(event.locationInWindow, from: nil)), event: event)
            needsDisplay = true
            return NSCursor.crosshair.set()
        }
        if state.draft != nil { return NSCursor.crosshair.set() }
        guard state.tool == .select else { return }
        let v = convert(event.locationInWindow, from: nil)
        if hitHandle(at: v) != nil || hitPathHandle(at: v) != nil {
            NSCursor.crosshair.set()
        } else if hitDot(at: v) == nil, hitPathLine(at: v) != nil {
            NSCursor.pointingHand.set()
        } else if let dot = hitDot(at: v) {
            let wholeForm = state.groups[dot.id].map { members in state.dots.filter(\.selected).count == members.count && dot.selected } ?? false
            (wholeForm ? NSCursor.openHand : NSCursor.arrow).set()
        } else if hitFormOutline(at: v) != nil {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// Note text scales with zoom like the field, within readable limits.
    private var noteFontSize: CGFloat { max(8, min(15, transform.scale * 1.3)) }

    /// The note's box in view coordinates and its text, laid out top-down from the anchor.
    private func layout(_ note: CanvasNote, offset: Point2 = .zero) -> (box: CGRect, text: NSAttributedString) {
        let size = noteFontSize
        let empty = note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let font = empty ? NSFontManager.shared.convert(NSFont.systemFont(ofSize: size), toHaveTrait: .italicFontMask) : NSFont.systemFont(ofSize: size)
        let text = NSAttributedString(string: empty ? "Empty note" : note.text,
                                      attributes: [.font: font, .foregroundColor: empty ? NSColor.gray : NSColor.black])
        let measured = text.boundingRect(with: CGSize(width: size * 16, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        let pad = size * 0.5
        let width = ceil(measured.width) + 2 * pad, height = ceil(measured.height) + 2 * pad
        let topLeft = view(note.position + offset)
        return (CGRect(x: topLeft.x, y: topLeft.y - height, width: width, height: height), text)
    }

    private func hitNote(at v: CGPoint) -> CanvasNote? {
        state?.notes.last { layout($0).box.contains(v) }
    }

    private func snapped(_ p: Point2, event: NSEvent) -> Point2 {
        guard let state, state.snapEnabled, !event.modifierFlags.contains(.option) else { return p }
        return state.field.snap(p, steps: state.snapSteps)
    }

    private func constrain(_ delta: Point2) -> Point2 {
        switch state?.axisLock ?? .none {
        case .none: return delta
        case .horizontal: return Point2(delta.x, 0)
        case .vertical: return Point2(0, delta.y)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let state else { return }
        let v = convert(event.locationInWindow, from: nil)
        if spaceDown || event.modifierFlags.contains(.control) {
            spaceUsedForPan = spaceDown
            drag = .pan(start: v, center: transform.center)
            NSCursor.closedHand.set()
            return
        }
        if curveToolActive {
            guard state.editable else { return }
            if state.draft == nil, !state.dots.contains(where: \.selected) {
                delegate?.canvasMessage("Select performers before drawing a curve.")
                return
            }
            let point = snapped(world(v), event: event)
            if let index = curvePoints.indices.min(by: { view(curvePoints[$0]).distance(to: v) < view(curvePoints[$1]).distance(to: v) }),
               view(curvePoints[index]).distance(to: v) <= 9 {
                curveHistory.append(curvePoints)
                curveDragIndex = index
            } else if event.clickCount < 2 {
                let index = Self.curveInsertionIndex(point, in: curvePoints)
                curveHistory.append(curvePoints)
                curvePoints.insert(point, at: index)
                curveDragIndex = index
            }
            curveHover = nil
            if event.clickCount > 1 { finishCurve() }
            needsDisplay = true
            return
        }
        if state.draft != nil {
            guard state.editable else { return }
            let p = snapped(world(v), event: event)
            drag = .drawShape(start: p, end: p)
            needsDisplay = true
            return
        }
        if let (form, index) = hitHandle(at: v) {
            drag = .handle(form: form, index: index, start: world(v), geometry: form.geometry)
            return
        }
        // Path handles: drag a waypoint, double-click to delete it, or drag a leg's midpoint to curve it.
        if let (path, handle) = hitPathHandle(at: v) {
            switch handle {
            case .waypoint(let i):
                if event.clickCount > 1 {
                    delegate?.canvasDeleteWaypoint(path.id, segment: i)
                } else {
                    drag = .waypoint(path: path, segment: i, point: path.path.pieces(from: path.start)[i].end)
                }
            case .curve(let i):
                curveSnaps = !event.modifierFlags.contains(.option)
                drag = .curve(path: path, segment: i, sagitta: path.path.pieces(from: path.start)[i].sagitta)
            }
            needsDisplay = true
            return
        }
        // Dragging the selected performer's path line pulls a new waypoint out at the nearest count.
        if state.tool == .select, hitDot(at: v) == nil, let (path, count) = hitPathLine(at: v) {
            drag = .insertWaypoint(path: path, count: count, point: ResolvedPath(path.path, from: path.start).point(at: count.doubleValue).point, moved: false)
            needsDisplay = true
            return
        }
        // Dragging a shown form's outline moves the whole form.
        if state.tool == .select, hitDot(at: v) == nil, let form = hitFormOutline(at: v) {
            beginFormMove(form, at: v)
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }
        // Clicking a note focuses it for editing in the inspector; dragging moves it.
        if hitDot(at: v) == nil, let note = hitNote(at: v) {
            delegate?.canvasFocusNote(note.id)
            if state.editable { drag = .moveNote(id: note.id, start: world(v), delta: .zero) }
            needsDisplay = true
            return
        }
        switch state.tool {
        case .line, .arc, .text, .curve:
            guard state.editable else {
                delegate?.canvasMessage("Select a set to edit it. The canvas is showing a moment between sets.")
                return
            }
            let p = snapped(world(v), event: event)
            drag = .form(start: p, end: p, startView: v)
        case .select:
            if let dot = hitDot(at: v) {
                let additive = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
                if additive {
                    delegate?.canvasSelect([dot.id], additive: true)
                    drag = .none
                    return
                }
                var ids = state.dots.filter(\.selected).map(\.id)
                let selected = Set(ids)
                let group = state.groups[dot.id]
                if !dot.selected {
                    // A form acts like a group: the first click selects all of it. Once you
                    // are working inside a form, clicks pick its members one at a time.
                    let inside = group.map { !selected.isEmpty && selected.isSubset(of: $0) } ?? false
                    let target: Set<PerformerID> = inside || event.clickCount > 1 ? [dot.id] : (group ?? [dot.id])
                    delegate?.canvasSelect(target, additive: false)
                    ids = Array(target)
                }
                // Clicking inside a larger selection narrows to that dot on release, except
                // in a selected form, where a double-click is needed so the form stays selected.
                let wholeForm = group != nil && group == selected
                let narrowTo = dot.selected && ids.count > 1 && (!wholeForm || event.clickCount > 1) ? dot.id : nil
                if state.editable {
                    drag = .moveDots(ids: ids, anchor: dot.point, start: world(v), delta: .zero, narrowTo: narrowTo)
                } else {
                    if let narrowTo { delegate?.canvasSelect([narrowTo], additive: false) }
                    delegate?.canvasMessage("Select a set to move performers. The canvas is showing a moment between sets.")
                }
            } else {
                let additive = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
                drag = .box(start: v, current: v, additive: additive)
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        if let index = curveDragIndex, curvePoints.indices.contains(index) {
            curvePoints[index] = snapped(world(v), event: event)
            needsDisplay = true
            return
        }
        switch drag {
        case .none:
            return
        case .pan(let start, let center):
            followsFieldFit = false
            transform.center = center - Point2(Double((v.x - start.x) / transform.scale), Double((v.y - start.y) / transform.scale))
        case .moveDots(let ids, let anchor, let start, _, let narrowTo):
            let raw = constrain(world(v) - start)
            let target = snapped(anchor + raw, event: event)
            drag = .moveDots(ids: ids, anchor: anchor, start: start, delta: constrain(target - anchor), narrowTo: narrowTo)
        case .box(let start, _, let additive):
            drag = .box(start: start, current: v, additive: additive)
        case .form(let start, _, let startView):
            drag = .form(start: start, end: snapped(world(v), event: event), startView: startView)
        case .handle(let form, let index, let start, _):
            let target = form.geometry.handles[index] + (world(v) - start)
            drag = .handle(form: form, index: index, start: start, geometry: form.geometry.movingHandle(index, to: snapped(target, event: event)))
        case .moveNote(let id, let start, _):
            drag = .moveNote(id: id, start: start, delta: constrain(world(v) - start))
        case .waypoint(let path, let i, _):
            drag = .waypoint(path: path, segment: i, point: snapped(world(v), event: event))
        case .insertWaypoint(let path, let count, _, _):
            drag = .insertWaypoint(path: path, count: count, point: snapped(world(v), event: event), moved: true)
        case .curve(let path, let i, _):
            curveSnaps = !event.modifierFlags.contains(.option)
            drag = .curve(path: path, segment: i, sagitta: sagitta(of: world(v), path: path, segment: i))
        case .drawShape(let start, _):
            drag = .drawShape(start: start, end: snapped(world(v), event: event))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        curveDragIndex = nil
        defer {
            drag = .none
            NSCursor.arrow.set()
            needsDisplay = true
        }
        guard let state else { return }
        switch drag {
        case .moveDots(let ids, _, _, let delta, let narrowTo):
            if delta.length > 1e-9 {
                delegate?.canvasCommitMove(ids, delta: delta)
            } else if let narrowTo {
                delegate?.canvasSelect([narrowTo], additive: false)
            }
        case .box(let start, let current, let additive):
            let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
            if rect.width < 3 && rect.height < 3 {
                if !additive { delegate?.canvasClearSelection() }
            } else {
                let ids = Set(state.dots.filter { rect.contains(view($0.point)) }.map(\.id))
                delegate?.canvasSelect(ids, additive: additive)
            }
        case .form(let start, let end, let startView):
            guard start.distance(to: end) > 0.25 else {
                // A click (not a drag) with Line or Arc still selects performers.
                if let dot = hitDot(at: startView) {
                    let additive = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
                    delegate?.canvasSelect([dot.id], additive: additive)
                } else {
                    delegate?.canvasMessage("Drag on the field to draw the \(state.tool.title.lowercased()).")
                }
                return
            }
            if state.tool == .text {
                delegate?.canvasCommitText(from: start, to: end)
                return
            }
            let geometry: FormGeometry = state.tool == .arc ? .arc(start: start, end: end, bulge: start.distance(to: end) * 0.25) : .line(start: start, end: end)
            delegate?.canvasCommitForm(geometry)
        case .handle(let form, _, _, let geometry):
            if geometry != form.geometry {
                delegate?.canvasCommitHandle(form.id, geometry: geometry)
            } else if event.clickCount > 1, let dot = hitDot(at: convert(event.locationInWindow, from: nil)) {
                // Double-clicking the performer under a handle selects just that performer.
                delegate?.canvasSelect([dot.id], additive: false)
            }
        case .moveNote(let id, _, let delta):
            if delta.length > 1e-9, let note = state.notes.first(where: { $0.id == id }) {
                delegate?.canvasCommitNoteMove(id, to: note.position + delta)
            }
        case .waypoint(let path, let i, let point):
            if point.distance(to: path.path.pieces(from: path.start)[i].end) > 1e-9 { delegate?.canvasCommitWaypoint(path.id, segment: i, to: point) }
        case .insertWaypoint(let path, let count, let point, let moved):
            if moved {
                delegate?.canvasInsertWaypoint(path.id, atCount: count, at: point)
            } else {
                delegate?.canvasMessage("Drag the path to add a waypoint at count \(count). Double-click a waypoint to remove it.")
            }
        case .curve(let path, let i, let sagitta):
            if abs(sagitta - path.path.pieces(from: path.start)[i].sagitta) > 1e-9 {
                delegate?.canvasCommitCurve(path.id, segment: i, sagitta: sagitta, snaps: curveSnaps)
            }
        case .drawShape(let start, let end):
            guard let draft = state.draft else { break }
            if start.distance(to: end) > 0.25 {
                delegate?.canvasCommitDraftShape(Self.drawnShape(draft.tool, from: start, to: end, text: state.text))
            } else {
                delegate?.canvasMessage("Drag on the field to draw a \(draft.tool.title.lowercased()).")
            }
        case .pan, .none:
            break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas {
            let factor = exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1))
            zoom(by: factor, at: v)
        } else {
            followsFieldFit = false
            transform.center = transform.center - Point2(Double(event.scrollingDeltaX / transform.scale), Double(-event.scrollingDeltaY / transform.scale))
        }
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let fine = event.modifierFlags.contains(.option)
        let coarse = event.modifierFlags.contains(.shift)
        let amount = fine ? 0.25 : (coarse ? 4 : 1)
        if curveToolActive, !curvePoints.isEmpty {
            switch event.keyCode {
            case 36, 76: finishCurve(); return
            case 53:
                cancelCurve()
                return
            case 51, 117:
                curvePoints = curveHistory.popLast() ?? []; curveHover = nil; curveDragIndex = nil
                needsDisplay = true
                return
            default: break
            }
        }
        switch event.keyCode {
        case 123: delegate?.canvasNudge(dx: -amount, dy: 0)
        case 124: delegate?.canvasNudge(dx: amount, dy: 0)
        case 125: delegate?.canvasNudge(dx: 0, dy: -amount)
        case 126: delegate?.canvasNudge(dx: 0, dy: amount)
        case 53:
            // Escape cancels a drag or tool preview before it clears the selection.
            if case .none = drag { delegate?.canvasClearSelection() } else { drag = .none; needsDisplay = true }
        case 51, 117:
            // Delete removes the focused note; performers are removed from the roster instead.
            if state?.draft != nil {
                delegate?.canvasRemoveLastDraftShape()
            } else if let note = state?.notes.first(where: \.focused) {
                delegate?.canvasDeleteNote(note.id)
            } else {
                super.keyDown(with: event)
            }
        case 49:
            if !event.isARepeat { spaceDown = true; spaceUsedForPan = false; NSCursor.openHand.set() }
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard event.keyCode == 49 else { return super.keyUp(with: event) }
        spaceDown = false
        NSCursor.arrow.set()
        if !spaceUsedForPan { delegate?.canvasTogglePlay() }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Zoomed field content must never paint into adjacent panes or the toolbar.
        ctx.clip(to: bounds)
        guard let state else { return }
        let field = state.field
        drawBackground(state, in: ctx)
        // Labels, selection rings and paths: white on dark fields, dark ink on paper.
        let ink = state.fieldStyle == .paper ? Tokens.Paper.ink : NSColor.white

        // The previous set, faint and unlabeled, behind everything while drawing the next set.
        for ghost in state.ghosts {
            drawSymbol(ghost.symbol, at: view(ghost.point), radius: dotRadius, color: Tokens.sectionColor(ghost.colorIndex).withAlphaComponent(0.3), in: ctx)
        }

        // Incoming paths with a tick at each count and hold markers; flagged paths are dashed with the warning color.
        for path in state.paths { drawPath(path, ink: ink, ctx: ctx) }
        ctx.setLineDash(phase: 0, lengths: [])

        // Field notes sit under the forms and dots so performers stay clickable.
        for note in state.notes {
            var offset = Point2.zero
            if case .moveNote(let id, _, let delta) = drag, id == note.id { offset = delta }
            let (box, text) = layout(note, offset: offset)
            NSColor.white.withAlphaComponent(0.94).setFill()
            box.fill()
            ctx.setStrokeColor(note.focused ? Tokens.fieldAccent.cgColor : NSColor.black.withAlphaComponent(0.75).cgColor)
            ctx.setLineWidth(note.focused ? 2 : 1)
            ctx.stroke(box.insetBy(dx: 0.5, dy: 0.5))
            let pad = noteFontSize * 0.5
            text.draw(with: box.insetBy(dx: pad, dy: pad), options: [.usesLineFragmentOrigin, .usesFontLeading])
        }

        // Forms and their handles.
        // Dot drag preview offset. Dragging every member of a form carries the form along.
        var previewDelta = Point2.zero
        var movingIDs = Set<PerformerID>()
        if case .moveDots(let ids, _, _, let delta, _) = drag { previewDelta = delta; movingIDs = Set(ids) }
        func shownGeometry(_ form: CanvasForm) -> FormGeometry {
            if case .handle(let dragged, _, _, let preview) = drag, dragged.id == form.id { return preview }
            if previewDelta.length > 0, form.members.isSubset(of: movingIDs) { return form.geometry.translated(by: previewDelta) }
            return form.geometry
        }

        // Form outlines.
        for form in state.forms {
            ctx.setStrokeColor(Tokens.fieldAccent.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(1.5)
            ctx.addLines(between: shownGeometry(form).polyline().map(view))
            ctx.strokePath()
            if state.editable, case .handle(let dragged, _, _, let preview) = drag, dragged.id == form.id {
                ctx.setFillColor(Tokens.fieldAccent.withAlphaComponent(0.5).cgColor)
                for p in preview.distribute(form.memberCount) {
                    let v = view(p)
                    ctx.fillEllipse(in: CGRect(x: v.x - dotRadius, y: v.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
                }
            }
        }

        // Draw Next Set shapes, dashed, with rings where the chosen performers would stand.
        if let draft = state.draft {
            ctx.setStrokeColor(Tokens.fieldAccent.withAlphaComponent(0.85).cgColor)
            ctx.setFillColor(Tokens.fieldAccent.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            for shape in draft.shapes { strokeOutlines(shape.outlines, in: ctx) }
            ctx.setLineDash(phase: 0, lengths: [])
            if !draft.routed, !(curveToolActive && curvePoints.count >= 2) {
                ctx.setStrokeColor(Tokens.fieldAccent.cgColor)
                for p in draft.preview {
                    let c = view(p)
                    ctx.strokeEllipse(in: CGRect(x: c.x - dotRadius, y: c.y - dotRadius, width: 2 * dotRadius, height: 2 * dotRadius))
                }
            }
        }

        // Dots. Paper uses a crisp ink edge; grass uses a soft dark halo.
        let r = dotRadius
        let showLabels = state.alwaysShowLabels || transform.scale >= 10
        // Labels shrink with the field through midrange zooms too, so they do not
        // turn a closely spaced form into a solid band of overlapping text.
        let labelScale = min(1, transform.scale / 30)
        let fontSize: CGFloat = state.alwaysShowLabels ? 8 : max(8, min(11, transform.scale * 0.6))
        let paper = state.fieldStyle == .paper
        let backingScale = window?.backingScaleFactor ?? 2
        if labelFontSize != fontSize || labelPaperStyle != paper || labelBackingScale != backingScale || labelCache.count > max(512, state.dots.count * 2) {
            labelCache.removeAll(keepingCapacity: true)
            labelFontSize = fontSize
            labelPaperStyle = paper
            labelBackingScale = backingScale
        }
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: ink.withAlphaComponent(0.9),
            .strokeColor: paper ? Tokens.Paper.paper : NSColor.black,
            .strokeWidth: -3
        ]
        for dot in state.dots {
            let p = view(movingIDs.contains(dot.id) ? dot.point + previewDelta : dot.point)
            let color = Tokens.sectionColor(dot.colorIndex)
            if paper {
                // A solid edge keeps pale colors visible, thinning with small dots so it does not fuse neighbors.
                drawSymbol(dot.symbol, at: p, radius: r + min(0.8, r * 0.3), color: Tokens.Paper.ink, in: ctx)
                drawSymbol(dot.symbol, at: p, radius: r, color: color, in: ctx)
            } else if state.fieldStyle == .grass {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 3 * r / 9, color: NSColor.black.withAlphaComponent(0.7).cgColor)
                drawSymbol(dot.symbol, at: p, radius: r, color: color, in: ctx)
                ctx.restoreGState()
            } else {
                drawSymbol(dot.symbol, at: p, radius: r, color: color, in: ctx)
            }
            if dot.selected {
                ctx.setStrokeColor(ink.cgColor)
                ctx.setLineWidth(2)
                ctx.strokeEllipse(in: CGRect(x: p.x - r - 3, y: p.y - r - 3, width: 2 * r + 6, height: 2 * r + 6))
            }
            if showLabels || dot.selected {
                ctx.saveGState()
                ctx.translateBy(x: p.x, y: p.y)
                ctx.scaleBy(x: labelScale, y: labelScale)
                let labelRadius = r / labelScale
                if let cached = labelCache[dot.label] {
                    cached.draw(at: .zero, radius: labelRadius, placement: state.labelPlacement, in: ctx)
                } else {
                    let text = NSAttributedString(string: dot.label, attributes: labelAttributes)
                    if let cached = Self.rasterizeLabel(text, scale: backingScale) {
                        labelCache[dot.label] = cached
                        cached.draw(at: .zero, radius: labelRadius, placement: state.labelPlacement, in: ctx)
                    } else {
                        let measured = text.size()
                        let size = CGSize(width: ceil(measured.width) + 2, height: ceil(measured.height) + 2)
                        let origin = state.labelPlacement.origin(at: .zero, radius: labelRadius, size: size)
                        text.draw(at: CGPoint(x: origin.x + 1, y: origin.y + 1))
                    }
                }
                ctx.restoreGState()
            }
        }

        // Reshape grips sit away from the performer dots; leaders show what they control.
        if state.editable {
            for form in state.forms {
                let geometry = shownGeometry(form)
                for (anchor, grip) in zip(geometry.handles, formHandlePositions(geometry)) {
                    ctx.setStrokeColor(Tokens.fieldAccent.withAlphaComponent(0.7).cgColor)
                    ctx.setLineWidth(1)
                    ctx.move(to: view(anchor))
                    ctx.addLine(to: grip)
                    ctx.strokePath()
                    let rect = CGRect(x: grip.x - handleRadius, y: grip.y - handleRadius,
                                      width: 2 * handleRadius, height: 2 * handleRadius)
                    ctx.setFillColor(NSColor.white.cgColor)
                    ctx.fill(rect)
                    ctx.setStrokeColor(Tokens.fieldAccent.cgColor)
                    ctx.setLineWidth(1.5)
                    ctx.stroke(rect)
                }
            }
        }

        // Path handles above the dots: rings on waypoints, diamonds on leg midpoints.
        if let path = editablePath { drawPathHandles(path, ctx: ctx) }

        // Gesture previews.
        switch drag {
        case .box(let start, let current, _):
            let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
            ctx.setFillColor(Tokens.fieldAccent.withAlphaComponent(0.12).cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(Tokens.fieldAccent.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(rect)
        case .form(let start, let end, _) where state.tool == .text:
            // Only the letters; dots are placed once the drag ends.
            ctx.setStrokeColor(Tokens.fieldAccent.withAlphaComponent(0.5).cgColor)
            ctx.setLineWidth(1)
            ctx.strokeLineSegments(between: [view(start), view(end)])
            ctx.setStrokeColor(Tokens.fieldAccent.cgColor)
            ctx.setFillColor(Tokens.fieldAccent.cgColor)
            ctx.setLineWidth(2)
            strokeOutlines(Self.drawnShape(.text, from: start, to: end, text: state.text).outlines, in: ctx)
        case .drawShape(let start, let end):
            guard let draft = state.draft else { break }
            if draft.tool == .text {
                ctx.setStrokeColor(Tokens.fieldAccent.withAlphaComponent(0.5).cgColor)
                ctx.setLineWidth(1)
                ctx.strokeLineSegments(between: [view(start), view(end)])
            }
            ctx.setStrokeColor(Tokens.fieldAccent.cgColor)
            ctx.setFillColor(Tokens.fieldAccent.cgColor)
            ctx.setLineWidth(2)
            strokeOutlines(Self.drawnShape(draft.tool, from: start, to: end, text: state.text).outlines, in: ctx)
        case .form(let start, let end, _):
            let geometry: FormGeometry = state.tool == .arc ? .arc(start: start, end: end, bulge: start.distance(to: end) * 0.25) : .line(start: start, end: end)
            ctx.setStrokeColor(Tokens.fieldAccent.cgColor)
            ctx.setLineWidth(2)
            ctx.addLines(between: geometry.polyline().map(view))
            ctx.strokePath()
            ctx.setFillColor(Tokens.fieldAccent.withAlphaComponent(0.6).cgColor)
            for p in geometry.distribute(max(state.dots.filter(\.selected).count, 2)) {
                let v = view(p)
                ctx.fillEllipse(in: CGRect(x: v.x - r, y: v.y - r, width: 2 * r, height: 2 * r))
            }
        case .moveDots(_, _, _, let delta, _) where delta.length > 0:
            let steps = delta.length / field.stepSize
            drawCaption("Δ \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), steps)) steps", at: CGPoint(x: 12, y: 32))
        default:
            break
        }
        if curveToolActive {
            var points = curvePoints
            if let hover = curveHover, !points.isEmpty {
                points.insert(hover, at: Self.curveInsertionIndex(hover, in: points))
            }
            ctx.setStrokeColor(Tokens.fieldAccent.cgColor)
            ctx.setFillColor(Tokens.fieldAccent.cgColor)
            ctx.setLineWidth(2)
            let geometry = FormGeometry.curve(points: points)
            strokeOutlines([geometry.polyline()], in: ctx)
            let preview: [Point2]
            if let draft = state.draft {
                preview = (try? Show(title: "Curve preview", field: state.field, movements: [], sets: []).drawnTargets(draft.shapes + [.curve(points: points)], count: draft.memberCount).flatMap { $0 }) ?? []
            } else {
                preview = points.count >= 2 ? geometry.distribute(state.dots.filter(\.selected).count) : []
            }
            for point in preview {
                let p = view(point)
                ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }
            for (index, point) in curvePoints.enumerated() {
                let p = view(point)
                ctx.fillEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
                drawCaption(index == 0 ? "Start" : (index == curvePoints.count - 1 ? "End" : "\(index)"), at: CGPoint(x: p.x + 9, y: p.y + 9))
            }

        }
        drawCaption(state.caption, at: CGPoint(x: 12, y: bounds.maxY - 24))
    }

    /// Text shaping and glyph rasterization happen once per label/style, not on every frame.
    static func rasterizeLabel(_ text: NSAttributedString, scale: CGFloat) -> LabelImage? {
        let measured = text.size()
        let size = CGSize(width: ceil(measured.width) + 2, height: ceil(measured.height) + 2)
        guard let bitmap = CGContext(data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)),
                                     bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        text.draw(at: CGPoint(x: 1, y: 1))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.makeImage(), let data = bitmap.data else { return nil }
        // Font line boxes include invisible ascender/descender space. Anchor front
        // labels to their actual ink instead, independent of zoom and font metrics.
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var minX = bitmap.width, minY = bitmap.height, maxX = -1, maxY = -1
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where pixels[y * bitmap.bytesPerRow + x * 4 + 3] > 0 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY,
              let inkImage = image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else {
            return LabelImage(image: image, size: size, inkImage: image, inkSize: size)
        }
        return LabelImage(image: image, size: size, inkImage: inkImage,
                          inkSize: CGSize(width: CGFloat(inkImage.width) / scale, height: CGFloat(inkImage.height) / scale))
    }

    /// Grid lines, hash marks and yard labels do not change when performers move.
    private func drawBackground(_ state: CanvasState, in ctx: CGContext) {
        let scale = window?.backingScaleFactor ?? 2
        let key = BackgroundKey(field: state.field, style: state.fieldStyle, bounds: bounds,
                                transform: transform, backingScale: scale)
        if backgroundCache?.key != key {
            let width = Int(ceil(bounds.width * scale)), height = Int(ceil(bounds.height * scale))
            guard width > 0, height > 0,
                  let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                paintBackground(state, in: ctx)
                return
            }
            bitmap.scaleBy(x: scale, y: scale)
            bitmap.translateBy(x: -bounds.minX, y: -bounds.minY)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
            paintBackground(state, in: bitmap)
            NSGraphicsContext.restoreGraphicsState()
            if let image = bitmap.makeImage() { backgroundCache = (key, image) }
        }
        if let image = backgroundCache?.image { ctx.draw(image, in: bounds) }
    }

    private func paintBackground(_ state: CanvasState, in ctx: CGContext) {
        (state.fieldStyle == .paper ? Tokens.Paper.paper : NSColor(hex: 0x111C24)).setFill()
        bounds.fill()
        let field = state.field
        let fieldRect = CGRect(origin: view(Point2(field.bounds.minX, field.bounds.minY)),
                               size: CGSize(width: CGFloat(field.length) * transform.scale, height: CGFloat(field.width) * transform.scale))
        switch state.fieldStyle {
        case .dark: drawSchematic(field, in: fieldRect, ctx: ctx)
        case .grass: drawGrass(field, in: fieldRect, ctx: ctx)
        case .paper: drawPaper(field, in: fieldRect, ctx: ctx)
        }
    }

    private func drawPath(_ path: CanvasPath, ink: NSColor, ctx: CGContext) {
        let segments = shownSegments(path)
        let route = PerformerPath(segments)
        let pieces = route.pieces(from: path.start)
        let editing = segments != path.segments
        let color = path.flagged ? Tokens.warning : (editing ? Tokens.fieldAccent : ink.withAlphaComponent(path.editable ? 0.6 : 0.35))
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(path.flagged || path.editable ? 1.5 : 1)
        ctx.setLineDash(phase: 0, lengths: path.flagged ? [5, 3] : [])
        ctx.addLines(between: polyline(pieces).map(view))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // A small tick at every whole count, once counts are far enough apart to read.
        let resolved = ResolvedPath(route, from: path.start)
        let total = route.totalCounts.doubleValue
        if transform.scale >= 4, total >= 2 {
            ctx.setFillColor(color.withAlphaComponent(0.9).cgColor)
            for k in 1..<Int(total.rounded(.up)) where Double(k) < total {
                let p = view(resolved.point(at: Double(k)).point)
                ctx.fillEllipse(in: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3))
            }
        }
        // Holds: a square where the performer marks time, with its length when zoomed in.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        for piece in pieces where piece.segment.isHold {
            let p = view(piece.start)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1.2)
            ctx.stroke(CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            if transform.scale >= 8 {
                let counts = piece.counts
                let label = "hold \(TimeFormat.decimal(counts.doubleValue, places: counts.isInteger ? 0 : 2))"
                NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color]).draw(at: CGPoint(x: p.x + 6, y: p.y - 14))
            }
        }
    }

    private func drawPathHandles(_ path: CanvasPath, ctx: CGContext) {
        let shown = CanvasPath(id: path.id, start: path.start, segments: shownSegments(path), editable: true, flagged: path.flagged)
        let hr = pathHandleRadius
        for (_, point) in waypointPoints(shown) {
            let rect = CGRect(x: view(point).x - hr, y: view(point).y - hr, width: 2 * hr, height: 2 * hr)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: rect)
            ctx.setStrokeColor(Tokens.fieldAccent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: rect)
        }
        for (_, point) in curvePoints(shown) {
            let v = view(point), d = hr * 0.8
            ctx.addLines(between: [CGPoint(x: v.x, y: v.y + d), CGPoint(x: v.x + d, y: v.y), CGPoint(x: v.x, y: v.y - d), CGPoint(x: v.x - d, y: v.y)])
            ctx.closePath()
            ctx.setFillColor(Tokens.fieldAccent.withAlphaComponent(0.85).cgColor)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.drawPath(using: .fillStroke)
        }
        if case .insertWaypoint(let dragged, _, let point, true) = drag, dragged.id == path.id {
            let v = view(point)
            ctx.setStrokeColor(Tokens.fieldAccent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(x: v.x - hr, y: v.y - hr, width: 2 * hr, height: 2 * hr))
        }
    }

    /// The dark editing surface with checkpoint lines whose strength varies by hierarchy.
    private func drawSchematic(_ field: Field, in fieldRect: CGRect, ctx: CGContext) {
        Tokens.field.setFill()
        fieldRect.fill()
        for cp in field.checkpoints {
            let alpha: CGFloat = cp.prominence == .major ? 0.9 : (cp.prominence == .hash ? 0.75 : 0.4)
            ctx.setStrokeColor(Tokens.grid.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(cp.prominence == .major ? 1.2 : 0.8)
            ctx.setLineDash(phase: 0, lengths: cp.prominence == .hash ? [4, 4] : [])
            if cp.axis == .x {
                let x = view(Point2(cp.position, 0)).x
                ctx.strokeLineSegments(between: [CGPoint(x: x, y: fieldRect.minY), CGPoint(x: x, y: fieldRect.maxY)])
            } else {
                let y = view(Point2(0, cp.position)).y
                ctx.strokeLineSegments(between: [CGPoint(x: fieldRect.minX, y: y), CGPoint(x: fieldRect.maxX, y: y)])
            }
        }
        ctx.setLineDash(phase: 0, lengths: [])
        drawCheckpointLabels(field, in: fieldRect, color: Tokens.grid.withAlphaComponent(0.95))
    }

    /// Mowed grass like the field picker's pictures: 5-yard stripes, darker end zones,
    /// white lines at their real 4-inch width, hash ticks every yard and yard numbers.
    private func drawGrass(_ field: Field, in fieldRect: CGRect, ctx: CGContext) {
        let s = transform.scale
        let yard = Field.yard, goal = 50 * yard
        (field.preset == .indoorFloor ? Tokens.Turf.tarp : Tokens.Turf.grass).setFill()
        fieldRect.fill()
        if field.isFootball {
            Tokens.Turf.stripe.setFill()
            for i in stride(from: 0, to: 20, by: 2) {
                let x0 = view(Point2(-goal + Double(i) * 5 * yard, 0)).x
                CGRect(x: x0, y: fieldRect.minY, width: CGFloat(5 * yard) * s, height: fieldRect.height).fill()
            }
            Tokens.Turf.endZone.setFill()
            let left = view(Point2(-goal, 0)).x, right = view(Point2(goal, 0)).x
            CGRect(x: fieldRect.minX, y: fieldRect.minY, width: left - fieldRect.minX, height: fieldRect.height).fill()
            CGRect(x: right, y: fieldRect.minY, width: fieldRect.maxX - right, height: fieldRect.height).fill()
        }

        let line = max(1, CGFloat(0.1016) * s)
        let white = NSColor.white
        for cp in field.checkpoints where cp.prominence != .hash {
            ctx.setStrokeColor(white.withAlphaComponent(cp.prominence == .major ? 0.95 : 0.8).cgColor)
            ctx.setLineWidth(line)
            if cp.axis == .x {
                let x = view(Point2(cp.position, 0)).x
                ctx.strokeLineSegments(between: [CGPoint(x: x, y: fieldRect.minY), CGPoint(x: x, y: fieldRect.maxY)])
            } else {
                let y = view(Point2(0, cp.position)).y
                ctx.strokeLineSegments(between: [CGPoint(x: fieldRect.minX, y: y), CGPoint(x: fieldRect.maxX, y: y)])
            }
        }
        // Hashes: a 2-foot tick every yard between the goal lines, or a dashed line off football fields.
        ctx.setStrokeColor(white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(line)
        for cp in field.checkpoints where cp.prominence == .hash {
            let y = view(Point2(0, cp.position)).y
            if field.isFootball {
                let tick = max(3, CGFloat(2 * Field.foot) * s) / 2
                var segments: [CGPoint] = []
                for yardLine in -49...49 where yardLine % 5 != 0 {
                    let x = view(Point2(Double(yardLine) * yard, 0)).x
                    segments += [CGPoint(x: x, y: y - tick), CGPoint(x: x, y: y + tick)]
                }
                ctx.strokeLineSegments(between: segments)
            } else {
                ctx.setLineDash(phase: 0, lengths: [6, 6])
                ctx.strokeLineSegments(between: [CGPoint(x: fieldRect.minX, y: y), CGPoint(x: fieldRect.maxX, y: y)])
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }

        // Yard numbers, 2 yards tall and 10 yards in from each sideline like the picker, once readable.
        let numberSize = CGFloat(2 * yard) * s
        if field.isFootball, numberSize >= 9 {
            let font = NSFont.systemFont(ofSize: numberSize, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: white.withAlphaComponent(0.85)]
            for cp in field.checkpoints where cp.axis == .x {
                guard let n = Int(cp.label), n % 10 == 0, n > 0 else { continue }
                let text = NSAttributedString(string: cp.label, attributes: attributes)
                let size = text.size()
                for y in [-field.width / 2 + 10 * yard, field.width / 2 - 10 * yard] {
                    let center = view(Point2(cp.position, y))
                    text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
                }
            }
        } else {
            drawCheckpointLabels(field, in: fieldRect, color: white.withAlphaComponent(0.85))
        }
    }

    /// Graph paper like a printed drill chart: a light grid every step and a stronger one
    /// every 4 steps across the whole view, gray yard lines and hashes, a black border, and
    /// line numbers outside both sidelines, upside down along the back as read from there.
    private func drawPaper(_ field: Field, in fieldRect: CGRect, ctx: CGContext) {
        let step = field.stepSize
        if CGFloat(step) * transform.scale >= 4 { strokeGrid(spacing: step, color: Tokens.Paper.gridMinor, width: 0.5, ctx: ctx) }
        if CGFloat(4 * step) * transform.scale >= 4 { strokeGrid(spacing: 4 * step, color: Tokens.Paper.gridMajor, width: 1, ctx: ctx) }

        ctx.setLineWidth(1)
        for cp in field.checkpoints {
            ctx.setStrokeColor(Tokens.Paper.line.withAlphaComponent(cp.prominence == .hash ? 0.7 : 1).cgColor)
            if cp.axis == .x {
                let x = view(Point2(cp.position, 0)).x
                ctx.strokeLineSegments(between: [CGPoint(x: x, y: fieldRect.minY), CGPoint(x: x, y: fieldRect.maxY)])
            } else {
                let y = view(Point2(0, cp.position)).y
                ctx.strokeLineSegments(between: [CGPoint(x: fieldRect.minX, y: y), CGPoint(x: fieldRect.maxX, y: y)])
            }
        }
        ctx.setStrokeColor(Tokens.Paper.border.cgColor)
        ctx.setLineWidth(1.2)
        ctx.stroke(fieldRect)

        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, min(20, transform.scale * 2)), weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Tokens.Paper.ink.withAlphaComponent(0.8)]
        for cp in field.checkpoints where cp.axis == .x && !cp.label.hasSuffix("end line") {
            let x = view(Point2(cp.position, 0)).x
            let text = NSAttributedString(string: cp.label, attributes: attributes)
            let size = text.size()
            text.draw(at: CGPoint(x: x - size.width / 2, y: fieldRect.minY - 4 - size.height))
            ctx.saveGState()
            ctx.translateBy(x: x, y: fieldRect.maxY + 4 + size.height / 2)
            ctx.rotate(by: .pi)
            text.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
            ctx.restoreGState()
        }
    }

    /// Grid lines across the whole view on multiples of `spacing` from field center,
    /// the same positions dots snap to.
    private func strokeGrid(spacing: Double, color: NSColor, width: CGFloat, ctx: CGContext) {
        let low = world(CGPoint(x: bounds.minX, y: bounds.minY)), high = world(CGPoint(x: bounds.maxX, y: bounds.maxY))
        var segments: [CGPoint] = []
        for i in Int((low.x / spacing).rounded(.down))...Int((high.x / spacing).rounded(.up)) {
            let x = view(Point2(Double(i) * spacing, 0)).x
            segments += [CGPoint(x: x, y: bounds.minY), CGPoint(x: x, y: bounds.maxY)]
        }
        for i in Int((low.y / spacing).rounded(.down))...Int((high.y / spacing).rounded(.up)) {
            let y = view(Point2(0, Double(i) * spacing)).y
            segments += [CGPoint(x: bounds.minX, y: y), CGPoint(x: bounds.maxX, y: y)]
        }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.strokeLineSegments(between: segments)
    }

    /// Small checkpoint names along the front edge, when zoomed in enough to fit.
    private func drawCheckpointLabels(_ field: Field, in fieldRect: CGRect, color: NSColor) {
        guard transform.scale > 3 else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: color]
        for cp in field.checkpoints where cp.axis == .x && !cp.label.hasSuffix("end line") {
            let x = view(Point2(cp.position, 0)).x
            let text = NSAttributedString(string: cp.label, attributes: attributes)
            text.draw(at: CGPoint(x: x - text.size().width / 2, y: fieldRect.minY + 4))
        }
    }

    private func drawCaption(_ text: String, at point: CGPoint) {
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                                       .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
        let size = attributed.size()
        let rect = CGRect(x: point.x - 6, y: point.y - 3, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(state?.fieldStyle == .paper ? 0.7 : 0.35).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        attributed.draw(at: point)
    }

    private func drawSymbol(_ symbol: PerformerSymbol, at p: CGPoint, radius r: CGFloat, color: NSColor, in ctx: CGContext) {
        ctx.setFillColor(color.cgColor)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(max(1.5 * min(1, r / 3.5), r * 0.35))
        switch symbol {
        case .circle:
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        case .cross:
            ctx.strokeLineSegments(between: [CGPoint(x: p.x - r, y: p.y - r), CGPoint(x: p.x + r, y: p.y + r),
                                             CGPoint(x: p.x - r, y: p.y + r), CGPoint(x: p.x + r, y: p.y - r)])
        case .square:
            ctx.fill(CGRect(x: p.x - r * 0.9, y: p.y - r * 0.9, width: 1.8 * r, height: 1.8 * r))
        case .triangle:
            ctx.addLines(between: [CGPoint(x: p.x, y: p.y + r), CGPoint(x: p.x + r, y: p.y - r * 0.8), CGPoint(x: p.x - r, y: p.y - r * 0.8)])
            ctx.closePath()
            ctx.fillPath()
        case .diamond:
            ctx.addLines(between: [CGPoint(x: p.x, y: p.y + r), CGPoint(x: p.x + r, y: p.y), CGPoint(x: p.x, y: p.y - r), CGPoint(x: p.x - r, y: p.y)])
            ctx.closePath()
            ctx.fillPath()
        case .slash:
            ctx.strokeLineSegments(between: [CGPoint(x: p.x - r, y: p.y - r), CGPoint(x: p.x + r, y: p.y + r)])
        }
    }

    private func updateAccessibility() {
        guard let state else { return }
        let selected = state.dots.filter(\.selected).count
        let notes = state.notes.isEmpty ? "" : " \(state.notes.count) note\(state.notes.count == 1 ? "" : "s")."
        let curved = state.paths.filter { path in path.segments.count > 1 || path.segments.contains { segment in if case .arc = segment { return true }; return false } }.count
        let paths = curved == 0 ? "" : " \(curved) shown path\(curved == 1 ? "" : "s") curve, hold or turn."
        let draft = state.draft.map { " Drawing the next set: \($0.shapes.count) shape\($0.shapes.count == 1 ? "" : "s") drawn. Drag to draw a \($0.tool.title.lowercased()); Delete removes the last shape." } ?? ""
        setAccessibilityValue("\(state.caption). \(state.dots.count) performers placed, \(selected) selected.\(notes)\(paths)\(draft) Arrow keys nudge the selection.")
    }
}
