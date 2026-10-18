import AppKit
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
            if !didFit { fit(.fitField) }
            needsDisplay = true
            updateAccessibility()
        }
    }

    private(set) var transform = CanvasTransform()
    private var didFit = false
    private var spaceDown = false
    /// Space toggles playback when tapped; Space-drag pans.
    private var spaceUsedForPan = false

    private enum Drag {
        case none
        case pan(start: CGPoint, center: Point2)
        case moveDots(ids: [PerformerID], anchor: Point2, start: Point2, delta: Point2)
        case box(start: CGPoint, current: CGPoint, additive: Bool)
        case form(start: Point2, end: Point2)
        case handle(form: CanvasForm, index: Int, geometry: FormGeometry)
    }

    private var drag: Drag = .none

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityIdentifier("canvas.field")
        setAccessibilityLabel("Field")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !didFit { fit(.fitField) }
    }

    // MARK: View commands

    func fit(_ command: CanvasViewCommand) {
        guard let state, bounds.width > 64, bounds.height > 64 else { return }
        switch command {
        case .fitField:
            transform = CanvasTransform.fit(state.field.bounds, in: bounds)
            didFit = true
        case .fitSelection:
            let points = state.dots.filter(\.selected).map(\.point)
            guard !points.isEmpty else { return fit(.fitField) }
            var rect = Rect2(points: points).insetBy(-4)
            if rect.width < 8 { rect = Rect2(minX: rect.center.x - 4, minY: rect.minY, maxX: rect.center.x + 4, maxY: rect.maxY) }
            if rect.height < 8 { rect = Rect2(minX: rect.minX, minY: rect.center.y - 4, maxX: rect.maxX, maxY: rect.center.y + 4) }
            transform = CanvasTransform.fit(rect, in: bounds)
        case .zoomIn:
            transform.zoom(by: 1.25, at: CGPoint(x: bounds.midX, y: bounds.midY), in: bounds)
        case .zoomOut:
            transform.zoom(by: 0.8, at: CGPoint(x: bounds.midX, y: bounds.midY), in: bounds)
        }
        needsDisplay = true
    }

    // MARK: Geometry helpers

    private var dotRadius: CGFloat { max(3.5, min(9, 0.3 * transform.scale)) }

    private func view(_ p: Point2) -> CGPoint { transform.toView(p, in: bounds) }
    private func world(_ v: CGPoint) -> Point2 { transform.toWorld(v, in: bounds) }

    private func hitDot(at v: CGPoint) -> CanvasDot? {
        guard let state else { return nil }
        let limit = dotRadius + 4
        var best: (CanvasDot, CGFloat)?
        for dot in state.dots {
            let p = view(dot.point)
            let d = hypot(p.x - v.x, p.y - v.y)
            if d <= limit, d < (best?.1 ?? .infinity) { best = (dot, d) }
        }
        return best?.0
    }

    private func hitHandle(at v: CGPoint) -> (CanvasForm, Int)? {
        guard let state, state.editable else { return nil }
        for form in state.forms {
            for (i, handle) in form.geometry.handles.enumerated() {
                let p = view(handle)
                if hypot(p.x - v.x, p.y - v.y) <= 7 { return (form, i) }
            }
        }
        return nil
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
        if let (form, index) = hitHandle(at: v) {
            drag = .handle(form: form, index: index, geometry: form.geometry)
            return
        }
        switch state.tool {
        case .line, .arc:
            guard state.editable else {
                delegate?.canvasMessage("Select a set to edit it. The canvas is showing a moment between sets.")
                return
            }
            let p = snapped(world(v), event: event)
            drag = .form(start: p, end: p)
        case .select:
            if let dot = hitDot(at: v) {
                let additive = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
                if additive {
                    delegate?.canvasSelect([dot.id], additive: true)
                    drag = .none
                    return
                }
                var ids = state.dots.filter(\.selected).map(\.id)
                if !dot.selected {
                    delegate?.canvasSelect([dot.id], additive: false)
                    ids = [dot.id]
                }
                if state.editable {
                    drag = .moveDots(ids: ids, anchor: dot.point, start: world(v), delta: .zero)
                } else {
                    delegate?.canvasMessage("Select a set to move performers. The canvas is showing a moment between sets.")
                }
            } else {
                drag = .box(start: v, current: v, additive: event.modifierFlags.contains(.shift))
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            return
        case .pan(let start, let center):
            transform.center = center - Point2(Double((v.x - start.x) / transform.scale), Double((v.y - start.y) / transform.scale))
        case .moveDots(let ids, let anchor, let start, _):
            let raw = constrain(world(v) - start)
            let target = snapped(anchor + raw, event: event)
            drag = .moveDots(ids: ids, anchor: anchor, start: start, delta: constrain(target - anchor))
        case .box(let start, _, let additive):
            drag = .box(start: start, current: v, additive: additive)
        case .form(let start, _):
            drag = .form(start: start, end: snapped(world(v), event: event))
        case .handle(let form, let index, _):
            drag = .handle(form: form, index: index, geometry: form.geometry.movingHandle(index, to: snapped(world(v), event: event)))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = .none
            NSCursor.arrow.set()
            needsDisplay = true
        }
        guard let state else { return }
        switch drag {
        case .moveDots(let ids, _, _, let delta):
            if delta.length > 1e-9 { delegate?.canvasCommitMove(ids, delta: delta) }
        case .box(let start, let current, let additive):
            let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
            if rect.width < 3 && rect.height < 3 {
                if !additive { delegate?.canvasClearSelection() }
            } else {
                let ids = Set(state.dots.filter { rect.contains(view($0.point)) }.map(\.id))
                delegate?.canvasSelect(ids, additive: additive)
            }
        case .form(let start, let end):
            guard start.distance(to: end) > 0.25 else {
                delegate?.canvasMessage("Drag on the field to draw the \(state.tool == .arc ? "arc" : "line").")
                return
            }
            let geometry: FormGeometry = state.tool == .arc ? .arc(start: start, end: end, bulge: start.distance(to: end) * 0.25) : .line(start: start, end: end)
            delegate?.canvasCommitForm(geometry)
        case .handle(let form, _, let geometry):
            if geometry != form.geometry { delegate?.canvasCommitHandle(form.id, geometry: geometry) }
        case .pan, .none:
            break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas {
            let factor = exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1))
            transform.zoom(by: factor, at: v, in: bounds)
        } else {
            transform.center = transform.center - Point2(Double(event.scrollingDeltaX / transform.scale), Double(-event.scrollingDeltaY / transform.scale))
        }
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        transform.zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil), in: bounds)
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let fine = event.modifierFlags.contains(.option)
        let coarse = event.modifierFlags.contains(.shift)
        let amount = fine ? 0.25 : (coarse ? 4 : 1)
        switch event.keyCode {
        case 123: delegate?.canvasNudge(dx: -amount, dy: 0)
        case 124: delegate?.canvasNudge(dx: amount, dy: 0)
        case 125: delegate?.canvasNudge(dx: 0, dy: -amount)
        case 126: delegate?.canvasNudge(dx: 0, dy: amount)
        case 53:
            // Escape cancels a drag or tool preview before it clears the selection.
            if case .none = drag { delegate?.canvasClearSelection() } else { drag = .none; needsDisplay = true }
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
        NSColor(hex: 0x111C24).setFill()
        bounds.fill()
        guard let state else { return }
        let field = state.field
        let fieldRect = CGRect(origin: view(Point2(field.bounds.minX, field.bounds.minY)),
                               size: CGSize(width: CGFloat(field.length) * transform.scale, height: CGFloat(field.width) * transform.scale))
        Tokens.field.setFill()
        fieldRect.fill()

        // Checkpoints: strength varies by hierarchy.
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                                                               .foregroundColor: Tokens.grid.withAlphaComponent(0.95)]
        for cp in field.checkpoints {
            let alpha: CGFloat = cp.prominence == .major ? 0.9 : (cp.prominence == .hash ? 0.75 : 0.4)
            ctx.setStrokeColor(Tokens.grid.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(cp.prominence == .major ? 1.2 : 0.8)
            ctx.setLineDash(phase: 0, lengths: cp.prominence == .hash ? [4, 4] : [])
            if cp.axis == .x {
                let x = view(Point2(cp.position, 0)).x
                ctx.strokeLineSegments(between: [CGPoint(x: x, y: fieldRect.minY), CGPoint(x: x, y: fieldRect.maxY)])
                if !cp.label.hasSuffix("end line"), transform.scale > 3 {
                    let text = NSAttributedString(string: cp.label, attributes: labelAttributes)
                    text.draw(at: CGPoint(x: x - text.size().width / 2, y: fieldRect.minY + 4))
                }
            } else {
                let y = view(Point2(0, cp.position)).y
                ctx.strokeLineSegments(between: [CGPoint(x: fieldRect.minX, y: y), CGPoint(x: fieldRect.maxX, y: y)])
            }
        }
        ctx.setLineDash(phase: 0, lengths: [])

        // Incoming paths for the selection; flagged paths are dashed with the warning color.
        for (id, a, b) in state.paths {
            let flagged = state.warningPaths.contains(id)
            ctx.setStrokeColor(flagged ? Tokens.warning.cgColor : NSColor.white.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(flagged ? 1.5 : 1)
            ctx.setLineDash(phase: 0, lengths: flagged ? [5, 3] : [])
            ctx.strokeLineSegments(between: [view(a), view(b)])
        }
        ctx.setLineDash(phase: 0, lengths: [])

        // Forms and their handles.
        for form in state.forms {
            var geometry = form.geometry
            if case .handle(let dragged, _, let preview) = drag, dragged.id == form.id { geometry = preview }
            ctx.setStrokeColor(Tokens.fieldAccent.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(1.5)
            let points = geometry.polyline().map(view)
            ctx.addLines(between: points)
            ctx.strokePath()
            if state.editable {
                for handle in geometry.handles {
                    let p = view(handle)
                    let r = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
                    NSColor.white.setFill()
                    ctx.fillEllipse(in: r)
                    ctx.setStrokeColor(Tokens.fieldAccent.cgColor)
                    ctx.strokeEllipse(in: r)
                }
                if case .handle(let dragged, _, let preview) = drag, dragged.id == form.id {
                    ctx.setFillColor(Tokens.fieldAccent.withAlphaComponent(0.5).cgColor)
                    for p in preview.distribute(form.memberCount) {
                        let v = view(p)
                        ctx.fillEllipse(in: CGRect(x: v.x - dotRadius, y: v.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
                    }
                }
            }
        }

        // Dots (with drag preview offset).
        var previewDelta = Point2.zero
        var movingIDs = Set<PerformerID>()
        if case .moveDots(let ids, _, _, let delta) = drag { previewDelta = delta; movingIDs = Set(ids) }
        let r = dotRadius
        let showLabels = transform.scale >= 10
        let labelFont = NSFont.systemFont(ofSize: max(8, min(11, transform.scale * 0.6)), weight: .medium)
        for dot in state.dots {
            let p = view(movingIDs.contains(dot.id) ? dot.point + previewDelta : dot.point)
            let color = Tokens.sectionColor(dot.colorIndex)
            drawSymbol(dot.symbol, at: p, radius: r, color: color, in: ctx)
            if dot.selected {
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(2)
                ctx.strokeEllipse(in: CGRect(x: p.x - r - 3, y: p.y - r - 3, width: 2 * r + 6, height: 2 * r + 6))
            }
            if showLabels || dot.selected {
                NSAttributedString(string: dot.label, attributes: [.font: labelFont, .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
                    .draw(at: CGPoint(x: p.x + r + 2, y: p.y + 1))
            }
        }

        // Gesture previews.
        switch drag {
        case .box(let start, let current, _):
            let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
            ctx.setFillColor(Tokens.fieldAccent.withAlphaComponent(0.12).cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(Tokens.fieldAccent.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(rect)
        case .form(let start, let end):
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
        case .moveDots(_, _, _, let delta) where delta.length > 0:
            let steps = delta.length / field.stepSize
            drawCaption("Δ \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), steps)) steps", at: CGPoint(x: 12, y: 32))
        default:
            break
        }
        drawCaption(state.caption, at: CGPoint(x: 12, y: bounds.maxY - 24))
    }

    private func drawCaption(_ text: String, at point: CGPoint) {
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                                       .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
        let size = attributed.size()
        let rect = CGRect(x: point.x - 6, y: point.y - 3, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        attributed.draw(at: point)
    }

    private func drawSymbol(_ symbol: PerformerSymbol, at p: CGPoint, radius r: CGFloat, color: NSColor, in ctx: CGContext) {
        ctx.setFillColor(color.cgColor)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(max(1.5, r * 0.35))
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
        setAccessibilityValue("\(state.caption). \(state.dots.count) performers placed, \(selected) selected. Arrow keys nudge the selection.")
    }
}
