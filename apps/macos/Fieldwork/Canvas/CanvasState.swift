import CoreGraphics
import DrillTiming
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

/// A performer's route through the move into the shown set: their stored path,
/// or one straight line. The canvas resolves it for drawing and edit previews.
struct CanvasPath: Equatable {
    var id: PerformerID
    var start: Point2
    var segments: [PathSegment]
    /// Shows waypoint and curve handles (one performer selected on an editable set).
    var editable: Bool
    /// Flagged by analysis: drawn dashed, in the warning color.
    var flagged: Bool

    var path: PerformerPath { PerformerPath(segments) }
    var counts: Rational { path.totalCounts }
}

/// Draw Next Set on the canvas: the drawn shapes, the shape the next drag makes,
/// and where the chosen performers would stand until they are routed.
struct CanvasDraft: Equatable {
    var shapes: [DrawnShape]
    var tool: DrawTool
    var preview: [Point2]
    var routed: Bool
}

/// How the canvas draws the field. A per-user view preference, not show data.
enum FieldStyle: String, CaseIterable, Identifiable {
    /// The dark editing surface with gray checkpoint lines.
    case dark
    /// Mowed grass with white lines and yard numbers, like the field picker.
    case grass
    /// Cream graph paper with a step grid, like a printed drill chart.
    case paper

    var id: Self { self }

    var title: String {
        switch self {
        case .dark: "Dark"
        case .grass: "Grass"
        case .paper: "Paper"
        }
    }
}

/// Screen-space label placement; the audience/front is below the field in this canvas.
enum PerformerLabelPlacement: String, CaseIterable, Identifiable {
    case front
    case offset

    var id: Self { self }
    var title: String {
        switch self {
        case .front: "In Front"
        case .offset: "Offset (Original)"
        }
    }

    func origin(at point: CGPoint, radius: CGFloat, size: CGSize) -> CGPoint {
        switch self {
        case .front:
            CGPoint(x: point.x - size.width / 2, y: point.y - radius - 1 - size.height)
        case .offset:
            CGPoint(x: point.x + radius + 1, y: point.y)
        }
    }
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
    /// Incoming routes (previous arrival → this arrival) for the selection, or everyone with Show All Paths.
    var paths: [CanvasPath]
    var editable: Bool
    var tool: EditorTool
    var snapEnabled: Bool
    var snapSteps: Double
    var axisLock: AxisLock
    var caption: String
    var fieldStyle: FieldStyle
    var alwaysShowLabels: Bool
    var labelPlacement: PerformerLabelPlacement
    /// The previous set's performers, drawn faintly behind everything while drawing the next set.
    var ghosts: [CanvasDot] = []
    var draft: CanvasDraft?
    /// What the Text tool spells.
    var text = ""

    static func == (a: CanvasState, b: CanvasState) -> Bool {
        a.field == b.field && a.fieldStyle == b.fieldStyle && a.alwaysShowLabels == b.alwaysShowLabels && a.labelPlacement == b.labelPlacement && a.dots == b.dots && a.notes == b.notes && a.forms == b.forms && a.groups == b.groups && a.editable == b.editable && a.tool == b.tool
            && a.snapEnabled == b.snapEnabled && a.snapSteps == b.snapSteps && a.axisLock == b.axisLock && a.caption == b.caption
            && a.paths == b.paths && a.ghosts == b.ghosts && a.draft == b.draft && a.text == b.text
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
    func canvasCommitWaypoint(_ id: PerformerID, segment: Int, to point: Point2)
    func canvasInsertWaypoint(_ id: PerformerID, atCount count: Rational, at point: Point2)
    func canvasDeleteWaypoint(_ id: PerformerID, segment: Int)
    func canvasCommitCurve(_ id: PerformerID, segment: Int, sagitta: Double, snaps: Bool)
    func canvasCommitText(from start: Point2, to end: Point2)
    func canvasCommitDraftShape(_ shape: DrawnShape)
    func canvasRemoveLastDraftShape()
}
