import Foundation
import DrillTiming
import DrillCore

public struct ExportError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct CoordinateExportOptions: Sendable {
    /// Performers to include in roster order; nil exports everyone.
    public var performerIDs: [PerformerID]?
    /// Rounding increment in steps.
    public var rounding: Double
    /// Include private roster names (off by default for shareable output).
    public var includeNames: Bool
    /// Append one overview chart page per set.
    public var includeSetCharts: Bool

    public init(performerIDs: [PerformerID]? = nil, rounding: Double = 0.25, includeNames: Bool = false, includeSetCharts: Bool = true) {
        self.performerIDs = performerIDs
        self.rounding = rounding
        self.includeNames = includeNames
        self.includeSetCharts = includeSetCharts
    }
}

/// One row of a performer's coordinate sheet. Also used by in-app previews.
public struct CoordinateRow: Hashable, Sendable {
    public var setLabel: String
    public var counts: String
    public var measure: String
    public var time: String
    public var sideToSide: String
    public var frontToBack: String
}

public enum CoordinateSheet {
    public static func rows(for performerID: PerformerID, in show: Show, movementID: MovementID, rounding: Double = 0.25) throws -> [CoordinateRow] {
        let map = try show.timingMap(for: movementID)
        let describer = CoordinateDescriber(field: show.field, rounding: rounding)
        let hasAudio = show.movement(movementID)?.audioAssetID != nil
        var rows: [CoordinateRow] = []
        var previousPulse: Rational?
        for set in show.sets(in: movementID) {
            let pulse = try map.pulse(at: set.cursor)
            let counts = previousPulse.map { TimeFormat.decimal((pulse - $0).doubleValue, places: (pulse - $0).isInteger ? 0 : 2) } ?? "Preset"
            previousPulse = pulse
            let time = hasAudio ? TimeFormat.clock(try map.audioTime(at: set.cursor)) : "-"
            let side: String, front: String
            switch show.formation(set.id)[performerID] {
            case .placed(let p):
                side = describer.sideToSide(p.x)
                front = describer.frontToBack(p.y)
            case .unresolved:
                side = "No position"
                front = "-"
            case .inactive:
                side = "Inactive"
                front = "-"
            }
            let measure = show.measureLabel(for: set, map: map)
            rows.append(CoordinateRow(setLabel: set.rehearsalMark.isEmpty ? set.label : "\(set.label) (\(set.rehearsalMark))", counts: counts,
                                      measure: measure.isEmpty ? "-" : measure,
                                      time: time, sideToSide: side, frontToBack: front))
        }
        return rows
    }

    /// Renders coordinate sheets (one or more pages per performer) and optional set charts.
    public static func render(_ show: Show, movementID: MovementID, options: CoordinateExportOptions = CoordinateExportOptions()) throws -> Data {
        guard let movement = show.movement(movementID) else { throw ExportError("Choose a movement to export.") }
        let ids = options.performerIDs ?? show.performers.map(\.id)
        let performers = ids.compactMap { show.performer($0) }
        guard !performers.isEmpty else { throw ExportError("Add performers to the roster before exporting coordinates.") }
        let sets = show.sets(in: movementID)
        guard !sets.isEmpty else { throw ExportError("The movement has no sets to export.") }

        let pdf = PDFWriter()
        let margin = 48.0
        let columns: [(String, Double)] = [("Set", 54), ("Counts", 44), ("Music", 74), ("Time", 60), ("Side to side", 144), ("Front to back", 140)]
        let rowHeight = 17.0
        let stepNote = "Step size \(TimeFormat.decimal(show.field.stepSize, places: 4)) m (\(TimeFormat.decimal(5 * Field.yard / show.field.stepSize, places: 1)) to 5) · rounded to \(TimeFormat.decimal(options.rounding, places: 2)) step"

        for performer in performers {
            let rows = try self.rows(for: performer.id, in: show, movementID: movementID, rounding: options.rounding)
            var index = 0
            var page = 1
            repeat {
                pdf.beginPage()
                pdf.setFill(.black)
                pdf.text(show.title, x: margin, baseline: margin + 4, size: 10, font: .regular)
                var heading = "\(performer.label)"
                if let section = show.section(performer.sectionID) { heading += "  \(section.name)" }
                if options.includeNames, let name = performer.name, !name.isEmpty { heading += "  \(name)" }
                pdf.text(heading, x: margin, baseline: margin + 30, size: 20, font: .bold)
                pdf.setFill(.gray)
                pdf.text("\(movement.name) · \(show.field.name)\(page > 1 ? " · continued" : "")", x: margin, baseline: margin + 48, size: 9)
                var top = margin + 66
                pdf.setStroke(.light)
                pdf.setLineWidth(0.6)
                var x = margin
                pdf.setFill(.gray)
                for (title, width) in columns {
                    pdf.text(title.uppercased(), x: x, baseline: top + 11, size: 7.5, font: .bold)
                    x += width
                }
                top += rowHeight
                pdf.line(margin, top - 3, pdf.pageWidth - margin, top - 3)
                let maxRows = Int((pdf.pageHeight - top - margin - 30) / rowHeight)
                var drawn = 0
                while index < rows.count, drawn < maxRows {
                    let row = rows[index]
                    let cells = [row.setLabel, row.counts, row.measure, row.time, row.sideToSide, row.frontToBack]
                    x = margin
                    for (i, (_, width)) in columns.enumerated() {
                        let missing = cells[i] == "No position"
                        pdf.setFill(missing ? .warning : .black)
                        pdf.text(cells[i], x: x, baseline: top + 12, size: 9.5, font: i <= 3 ? .mono : (missing ? .bold : .regular))
                        x += width
                    }
                    top += rowHeight
                    pdf.line(margin, top - 3, pdf.pageWidth - margin, top - 3)
                    index += 1
                    drawn += 1
                }
                pdf.setFill(.gray)
                pdf.text(stepNote, x: margin, baseline: pdf.pageHeight - margin + 10, size: 7.5)
                page += 1
            } while index < rows.count
        }

        if options.includeSetCharts {
            let map = try show.timingMap(for: movementID)
            for set in sets {
                pdf.beginPage()
                drawChart(pdf, show: show, set: set, map: map, margin: margin, includeIDs: Set(ids))
            }
        }
        return pdf.finish(title: "\(show.title) coordinates")
    }

    static func drawChart(_ pdf: PDFWriter, show: Show, set: ArrivalSet, map: TimingMap, margin: Double, includeIDs: Set<PerformerID>) {
        let field = show.field
        let counts = (try? show.moveCounts(into: set.id)).map { $0.isZero ? "Preset" : "\(TimeFormat.decimal($0.doubleValue, places: $0.isInteger ? 0 : 2)) counts" } ?? ""
        let music = show.measureLabel(for: set, map: map)
        let count = show.cumulativeCount(of: set, map: map).map { "count \(TimeFormat.decimal($0.doubleValue, places: $0.isInteger ? 0 : 2))" } ?? ""
        pdf.setFill(.black)
        pdf.text(show.title, x: margin, baseline: margin + 4, size: 10)
        pdf.text(set.rehearsalMark.isEmpty ? "Set \(set.label)" : "Set \(set.label) · \(set.rehearsalMark)", x: margin, baseline: margin + 30, size: 20, font: .bold)
        pdf.setFill(.gray)
        pdf.text([music, count, counts].filter { !$0.isEmpty }.joined(separator: " · "), x: margin, baseline: margin + 48, size: 9)

        let width = pdf.pageWidth - 2 * margin
        let scale = width / field.length
        let height = field.width * scale
        let top = margin + 70
        func px(_ x: Double) -> Double { margin + (x + field.length / 2) * scale }
        // +y (back sideline) is drawn at the top; the audience is at the bottom of the page.
        func py(_ y: Double) -> Double { top + (field.width / 2 - y) * scale }

        pdf.setStroke(.gray)
        pdf.setLineWidth(0.8)
        pdf.rect(margin, top, width, height)
        for cp in field.checkpoints {
            pdf.setStroke(cp.prominence == .minor ? .light : .gray)
            pdf.setLineWidth(cp.prominence == .major ? 0.7 : 0.4)
            if cp.prominence == .hash { pdf.setDash([2, 3]) }
            if cp.axis == .x {
                pdf.line(px(cp.position), top, px(cp.position), top + height)
                if !cp.label.hasSuffix("end line") {
                    pdf.setFill(.gray)
                    pdf.text(cp.label, x: px(cp.position) - PDFWriter.width(cp.label, size: 6) / 2, baseline: top + height + 9, size: 6)
                }
            } else {
                pdf.line(margin, py(cp.position), margin + width, py(cp.position))
            }
            if cp.prominence == .hash { pdf.setDash([]) }
        }
        let formation = show.formation(set.id)
        let radius = max(1.6, min(3.2, 0.45 * scale))
        for performer in show.performers where includeIDs.contains(performer.id) {
            guard let p = formation[performer.id].position else { continue }
            pdf.setFill(.accent)
            pdf.circle(px(p.x), py(p.y), radius, fill: true)
            pdf.setFill(.black)
            pdf.text(performer.label, x: px(p.x) + radius + 0.8, baseline: py(p.y) - radius, size: 5)
        }
        let missing = show.performers.filter { includeIDs.contains($0.id) && formation[$0.id].position == nil }
        pdf.setFill(missing.isEmpty ? .gray : .warning)
        let note = missing.isEmpty ? "All \(includeIDs.count) performers placed. Audience at the bottom of the page."
            : "No position: \(missing.prefix(20).map(\.label).joined(separator: ", "))\(missing.count > 20 ? " and \(missing.count - 20) more" : "")"
        pdf.text(note, x: margin, baseline: top + height + 26, size: 8, font: missing.isEmpty ? .regular : .bold)
    }
}
