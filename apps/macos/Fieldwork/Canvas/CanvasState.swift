import CoreGraphics
import DrillCore

/// World (meters, +y toward the back sideline) ↔ view (points, non-flipped,
/// +y up) transform. The audience is at the bottom of the canvas.
struct CanvasTransform: Equatable {
    /// Points per meter.
    var scale: CGFloat = 8
    /// World point shown at the view's center.
    var center = Point2.zero

    func toView(_ p: Point2, in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.midX + CGFloat(p.x - center.x) * scale, y: bounds.midY + CGFloat(p.y - center.y) * scale)
    }

    func toWorld(_ v: CGPoint, in bounds: CGRect) -> Point2 {
        Point2(center.x + Double((v.x - bounds.midX) / scale), center.y + Double((v.y - bounds.midY) / scale))
    }

    /// Zooms by `factor`, keeping the world point under `anchor` fixed.
    mutating func zoom(by factor: CGFloat, at anchor: CGPoint, in bounds: CGRect) {
        let before = toWorld(anchor, in: bounds)
        scale = min(max(scale * factor, 1), 200)
        let after = toWorld(anchor, in: bounds)
        center = center + (before - after)
    }

    static func fit(_ rect: Rect2, in bounds: CGRect, margin: CGFloat = 32) -> CanvasTransform {
        guard rect.width > 0, rect.height > 0, bounds.width > 2 * margin, bounds.height > 2 * margin else { return CanvasTransform() }
        let s = min((bounds.width - 2 * margin) / CGFloat(rect.width), (bounds.height - 2 * margin) / CGFloat(rect.height))
        return CanvasTransform(scale: max(s, 1), center: rect.center)
    }
}

extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }

    /// Distance to the segment from `a` to `b`.
    func distance(toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(to: a) }
        let t = max(0, min(1, ((x - a.x) * dx + (y - a.y) * dy) / lengthSquared))
        return distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}

struct CanvasDot: Equatable {
    var id: PerformerID
    var label: String
    var point: Point2
    var colorIndex: Int
    var symbol: PerformerSymbol
    var selected: Bool
}

/// A text box on the field. `position` is its top-left corner in meters.
struct CanvasNote: Equatable {
    var id: NoteID
    var text: String
    var position: Point2
    var focused: Bool
}

struct CanvasForm: Equatable {
    var id: FormID
    var geometry: FormGeometry
    var members: Set<PerformerID>
    var memberCount: Int { members.count }
}

/// Immutable snapshot the canvas draws. Built by the representable from the editor model.
struct CanvasState: Equatable {
    var field: Field
    var dots: [CanvasDot]
    /// Notes on the current set; empty during playback and between sets.
    var notes: [CanvasNote]
    /// Forms on the current set whose members are selected (handles shown when editable).
    var forms: [CanvasForm]
    /// Every member of a form on the current set, mapped to all of that form's
    /// members. A click on a member selects the whole form, like a group.
    var groups: [PerformerID: Set<PerformerID>]
    /// Straight incoming paths (previous arrival → this arrival) for selected performers.
    var paths: [(PerformerID, Point2, Point2)]
    /// Paths flagged by analysis (drawn dashed, in the warning color).
    var warningPaths: Set<PerformerID>
    var editable: Bool
    var tool: EditorTool
    var snapEnabled: Bool
    var snapSteps: Double
    var axisLock: AxisLock
    var caption: String

    static func == (a: CanvasState, b: CanvasState) -> Bool {
        a.field == b.field && a.dots == b.dots && a.notes == b.notes && a.forms == b.forms && a.groups == b.groups && a.editable == b.editable && a.tool == b.tool
            && a.snapEnabled == b.snapEnabled && a.snapSteps == b.snapSteps && a.axisLock == b.axisLock && a.caption == b.caption
            && a.warningPaths == b.warningPaths && a.paths.count == b.paths.count
            && zip(a.paths, b.paths).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 }
    }
}

/// Semantic intents the canvas reports. Previews stay inside the canvas; only
/// committed results reach the model (one command per gesture).
@MainActor
protocol FieldCanvasDelegate: AnyObject {
    func canvasSelect(_ ids: Set<PerformerID>, additive: Bool)
    func canvasCommitMove(_ ids: [PerformerID], delta: Point2)
    func canvasCommitForm(_ geometry: FormGeometry)
    func canvasCommitHandle(_ form: FormID, geometry: FormGeometry)
    func canvasNudge(dx: Double, dy: Double)
    func canvasClearSelection()
    func canvasMessage(_ text: String)
    func canvasTogglePlay()
    func canvasFocusNote(_ id: NoteID)
    func canvasCommitNoteMove(_ id: NoteID, to position: Point2)
    func canvasDeleteNote(_ id: NoteID)
}
