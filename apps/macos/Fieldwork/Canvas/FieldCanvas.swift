import SwiftUI
import DrillTiming
import DrillCore

/// Hosts the AppKit field canvas inside the SwiftUI editor.
struct FieldCanvas: NSViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> FieldCanvasView {
        let view = FieldCanvasView(frame: .zero)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: FieldCanvasView, context: Context) {
        view.state = model.canvasState()
        if let request = model.canvasRequest, request.token != context.coordinator.lastRequest {
            context.coordinator.lastRequest = request.token
            view.fit(request.command)
        }
    }

    @MainActor
    final class Coordinator: NSObject, FieldCanvasDelegate {
        let model: EditorModel
        var lastRequest: UUID?

        init(model: EditorModel) { self.model = model }

        func canvasSelect(_ ids: Set<PerformerID>, additive: Bool) {
            if additive { model.selection.formSymmetricDifference(ids) } else { model.selection = ids }
        }
        func canvasCommitMove(_ ids: [PerformerID], delta: Point2) { model.commitMove(ids, by: delta) }
        func canvasCommitForm(_ geometry: FormGeometry) { model.commitForm(geometry) }
        func canvasCommitHandle(_ form: FormID, geometry: FormGeometry) { model.commitHandle(form, geometry: geometry) }
        func canvasNudge(dx: Double, dy: Double) { model.nudge(dx: dx, dy: dy) }
        func canvasClearSelection() { model.selection = [] }
        func canvasMessage(_ text: String) { model.statusMessage = text }
        func canvasTogglePlay() { model.togglePlay() }
    }
}

extension EditorModel {
    /// Builds the immutable canvas snapshot: the current set when editing, or the
    /// evaluated frame at the playhead while playing or scrubbing between sets.
    func canvasState() -> CanvasState {
        let show = self.show
        let sections = Dictionary(uniqueKeysWithValues: show.sections.map { ($0.id, $0) })
        var dots: [CanvasDot] = []
        var caption = ""
        let map = self.map
        if isEditable || evaluator == nil {
            let formation = show.formation(currentSetID)
            for performer in show.performers {
                guard let p = formation[performer.id].position else { continue }
                let section = sections[performer.sectionID]
                dots.append(CanvasDot(id: performer.id, label: performer.label, point: p.point, colorIndex: section?.colorIndex ?? 0,
                                      symbol: section?.symbol ?? .circle, selected: selection.contains(performer.id)))
            }
            if let set = currentSet {
                let music = (try? map?.musicalPosition(at: set.cursor).label) ?? ""
                caption = "Set \(set.label) · \(music)"
                if readOnlyReason != nil { caption += " · read-only" }
            }
        } else if let evaluator {
            let scene = evaluator.evaluate(audioTime: playheadSeconds)
            let byID = Dictionary(uniqueKeysWithValues: show.performers.map { ($0.id, $0) })
            for p in scene.performers where p.state == .placed {
                guard let performer = byID[p.id] else { continue }
                let section = sections[performer.sectionID]
                dots.append(CanvasDot(id: p.id, label: performer.label, point: Point2(p.x, p.y), colorIndex: section?.colorIndex ?? 0,
                                      symbol: section?.symbol ?? .circle, selected: selection.contains(p.id)))
            }
            let from = evaluator.sets[scene.setIndex].label
            if let next = scene.nextSetIndex {
                caption = "Count \(TimeFormat.decimal(scene.pulse, places: 1)) · moving to Set \(evaluator.sets[next].label)"
            } else {
                caption = "Count \(TimeFormat.decimal(scene.pulse, places: 1)) · Set \(from)"
            }
            if !isPlaying { caption += " · select a set to edit" }
        }

        var forms: [CanvasForm] = []
        var paths: [(PerformerID, Point2, Point2)] = []
        if isEditable {
            forms = show.forms(on: currentSetID).filter { !selection.isDisjoint(with: $0.members) }
                .map { CanvasForm(id: $0.id, geometry: $0.geometry, memberCount: $0.members.count) }
            if let previous = show.previousSet(before: currentSetID) {
                let before = show.formation(previous.id), now = show.formation(currentSetID)
                for id in selection {
                    if let a = before[id].position?.point, let b = now[id].position?.point, a.distance(to: b) > 1e-6 { paths.append((id, a, b)) }
                }
            }
        }
        let flagged = Set(analysisIssues.filter { $0.setID == currentSetID && $0.kind == .largeStride }.flatMap(\.performers))
        return CanvasState(field: show.field, dots: dots, forms: forms, paths: paths, warningPaths: flagged, editable: isEditable, tool: tool,
                           snapEnabled: snapEnabled, snapSteps: snapSteps, axisLock: axisLock, caption: caption)
    }
}
