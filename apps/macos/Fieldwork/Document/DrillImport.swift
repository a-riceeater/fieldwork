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
        let text = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: #"name="audio-offset-seconds">\s*([+-]?[0-9.]+)"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range])
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
