import AppKit
import UniformTypeIdentifiers
import DrillConvert

/// Opening a `.3du` drill. Fieldwork never edits a drill directly: the import
/// dialog converts it with the bundled converter into a `.fieldwork` file the
/// user names, and that file then opens like any other show.
enum DrillImport {
    /// Document types Fieldwork imports instead of opening (Info.plist declares them with the Viewer role).
    static func isImported(_ typeName: String) -> Bool {
        UTType(typeName)?.tags[.filenameExtension]?.contains("3du") == true
    }

    static func isDrill(_ url: URL) -> Bool {
        if url.pathExtension.caseInsensitiveCompare("3du") == .orderedSame { return true }
        return (try? NSDocumentController.shared.typeForContents(of: url)).map(isImported) ?? false
    }

    /// Why an import failed, naming the converter build for bug reports.
    static func explain(_ error: Error) -> String {
        let reason: String
        if let error = error as? ConverterError {
            reason = [error.errorDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: "\n")
        } else {
            reason = error.localizedDescription
        }
        return "\(reason)\n\nConverter: \(ConverterLocator.buildInfo()?.summary ?? "build information missing")"
    }

    /// The audio time of count 0 that the converter used for a count track, from
    /// the `audio-offset-seconds` note it writes into the MusicXML identification.
    static func audioOffset(inMusicXML data: Data) -> Double? {
        musicXMLNote(#"name="audio-offset-seconds">\s*([+-]?[0-9.]+)"#, in: data).first.flatMap(Double.init)
    }

    /// The converter's beat-hit rate and the rate chance gives, from its
    /// `alignment-beat-hits` note, such as "0.31 (chance 0.28)".
    static func alignmentHits(inMusicXML data: Data) -> (rate: Double, chance: Double)? {
        let values = musicXMLNote(#"name="alignment-beat-hits">\s*([0-9.]+)\s*\(chance\s*([0-9.]+)\)"#, in: data).compactMap(Double.init)
        return values.count == 2 ? (values[0], values[1]) : nil
    }

    /// The capture groups of `pattern` in the MusicXML header.
    private static func musicXMLNote(_ pattern: String, in data: Data) -> [String] {
        let text = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
        return (1..<match.numberOfRanges).compactMap { group in Range(match.range(at: group), in: text).map { range in String(text[range]) } }
    }
}

/// Sends `.3du` drills to the import dialog. Every route that opens a file
/// (File ▸ Open, Open Recent, the Welcome window, the Dock and Finder) passes
/// through `openDocument(withContentsOf:display:completionHandler:)`.
///
/// It must be the first document controller created, which makes it
/// `NSDocumentController.shared` (see `AppDelegate.main`).
final class FieldworkDocumentController: NSDocumentController {
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool, completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        guard DrillImport.isDrill(url) else {
            return super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
        }
        noteNewRecentDocumentURL(url)
        DrillImportWindowController.present(source: url) { [weak self] show, report in
            self?.openConverted(show, report: report)
        }
        // No document yet; the dialog opens the converted show if the user converts.
        completionHandler(nil, false, nil)
    }

    private func openConverted(_ url: URL, report: ImportReport) {
        super.openDocument(withContentsOf: url, display: true) { document, _, error in
            if let error { NSApp.presentError(error) }
            (document as? FieldworkDocument)?.importReport = report
        }
    }
}
