import Foundation

/// Small original PDF 1.4 writer: vector lines, rectangles, circles and text
/// in the standard Helvetica/Courier fonts (no font embedding). Page space is
/// points with the origin at the top-left for convenience.
public final class PDFWriter {
    public enum Font: String {
        case regular = "F1", bold = "F2", mono = "F3"
    }

    public struct Color: Sendable {
        public var r: Double, g: Double, b: Double
        public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
        public static let black = Color(0.09, 0.09, 0.13)
        public static let gray = Color(0.38, 0.40, 0.46)
        public static let light = Color(0.82, 0.84, 0.88)
        public static let accent = Color(0.157, 0.408, 0.910)
        public static let warning = Color(0.66, 0.37, 0.0)
    }

    public let pageWidth: Double
    public let pageHeight: Double
    private var pages: [String] = []
    private var current = ""

    /// US Letter by default.
    public init(pageWidth: Double = 612, pageHeight: Double = 792) {
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
    }

    public var pageCount: Int { pages.count + (current.isEmpty ? 0 : 1) }

    public func beginPage() {
        if !current.isEmpty { pages.append(current) }
        current = " "
    }

    private func y(_ top: Double) -> Double { pageHeight - top }
    private func n(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        if r == r.rounded() { return String(Int(r)) }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), r)
    }

    public func setStroke(_ c: Color) { current += "\(n(c.r)) \(n(c.g)) \(n(c.b)) RG\n" }
    public func setFill(_ c: Color) { current += "\(n(c.r)) \(n(c.g)) \(n(c.b)) rg\n" }
    public func setLineWidth(_ w: Double) { current += "\(n(w)) w\n" }
    public func setDash(_ pattern: [Double]) { current += "[\(pattern.map(n).joined(separator: " "))] 0 d\n" }

    public func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
        current += "\(n(x0)) \(n(y(y0))) m \(n(x1)) \(n(y(y1))) l S\n"
    }

    public func polyline(_ points: [(Double, Double)]) {
        guard let first = points.first else { return }
        current += "\(n(first.0)) \(n(y(first.1))) m"
        for p in points.dropFirst() { current += " \(n(p.0)) \(n(y(p.1))) l" }
        current += " S\n"
    }

    public func rect(_ x: Double, _ top: Double, _ w: Double, _ h: Double, fill: Bool = false, stroke: Bool = true) {
        current += "\(n(x)) \(n(y(top + h))) \(n(w)) \(n(h)) re \(fill && stroke ? "B" : fill ? "f" : "S")\n"
    }

    public func circle(_ cx: Double, _ cy: Double, _ r: Double, fill: Bool) {
        let k = 0.5523 * r
        let yy = y(cy)
        current += "\(n(cx + r)) \(n(yy)) m "
        current += "\(n(cx + r)) \(n(yy + k)) \(n(cx + k)) \(n(yy + r)) \(n(cx)) \(n(yy + r)) c "
        current += "\(n(cx - k)) \(n(yy + r)) \(n(cx - r)) \(n(yy + k)) \(n(cx - r)) \(n(yy)) c "
        current += "\(n(cx - r)) \(n(yy - k)) \(n(cx - k)) \(n(yy - r)) \(n(cx)) \(n(yy - r)) c "
        current += "\(n(cx + k)) \(n(yy - r)) \(n(cx + r)) \(n(yy - k)) \(n(cx + r)) \(n(yy)) c "
        current += fill ? "f\n" : "S\n"
    }

    /// Draws text with its baseline at `baseline` (top-origin coordinates).
    public func text(_ string: String, x: Double, baseline: Double, size: Double, font: Font = .regular) {
        current += "BT /\(font.rawValue) \(n(size)) Tf \(n(x)) \(n(y(baseline))) Td (\(PDFWriter.escape(string))) Tj ET\n"
    }

    /// Approximate text width for layout (Helvetica average advance; Courier exact).
    public static func width(_ string: String, size: Double, font: Font = .regular) -> Double {
        font == .mono ? Double(string.count) * 0.6 * size : Double(string.count) * (font == .bold ? 0.56 : 0.52) * size
    }

    /// Escapes PDF string syntax and maps text to WinAnsi-compatible ASCII.
    static func escape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "(": out += "\\("
            case ")": out += "\\)"
            case "\\": out += "\\\\"
            case "\u{2013}", "\u{2014}": out += "-"
            case "\u{00D7}": out += "x"
            case "\u{00B7}", "\u{2022}": out += "-"
            case "\u{2018}", "\u{2019}": out += "'"
            case "\u{201C}", "\u{201D}": out += "\""
            default:
                out += scalar.value >= 32 && scalar.value < 127 ? String(scalar) : "?"
            }
        }
        return out
    }

    /// Assembles the PDF file. Object layout: 1 catalog, 2 pages, 3–5 fonts, then page/content pairs.
    public func finish(title: String) -> Data {
        if !current.isEmpty { pages.append(current); current = "" }
        if pages.isEmpty { pages.append(" ") }
        var objects: [String] = []
        let pageObjectStart = 6
        let kids = pages.indices.map { "\(pageObjectStart + $0 * 2) 0 R" }.joined(separator: " ")
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append("<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>")
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>")
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>")
        for (i, content) in pages.enumerated() {
            let contentRef = pageObjectStart + i * 2 + 1
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(n(pageWidth)) \(n(pageHeight))] /Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R >> >> /Contents \(contentRef) 0 R >>")
            objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        }
        let infoNumber = objects.count + 1
        objects.append("<< /Title (\(PDFWriter.escape(title))) /Producer (Fieldwork) >>")

        var out = "%PDF-1.4\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n"
        var data = Data(out.utf8)
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(i + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xref = data.count
        out = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            let s = String(offset)
            out += String(repeating: "0", count: 10 - s.count) + s + " 00000 n \n"
        }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info \(infoNumber) 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        data.append(Data(out.utf8))
        return data
    }
}
