import XCTest
import AppKit
import DrillConvert
@testable import Fieldwork

/// The import dialog's rules: what it needs before Convert, and the converter
/// options it asks for. Choosing files and converting need panels and the real
/// converter; `BundledConverterTests` and the DrillConvert tests cover those.
@MainActor
final class DrillImportTests: XCTestCase {
    private let drill = URL(fileURLWithPath: "/tmp/show.3du")

    func testDrillsGoThroughTheImportController() {
        XCTAssertTrue(NSDocumentController.shared is FieldworkDocumentController)
        XCTAssertTrue(DrillImport.isDrill(drill))
        XCTAssertTrue(DrillImport.isDrill(URL(fileURLWithPath: "/tmp/SHOW.3DU")))
        XCTAssertFalse(DrillImport.isDrill(URL(fileURLWithPath: "/tmp/show.fieldwork")))
    }

    func testConvertNeedsAShowDestination() {
        let model = DrillImportModel(source: drill)
        XCTAssertEqual(model.name, "show")
        XCTAssertEqual(model.missing, "Choose where to save the show.")
        model.showDestination = URL(fileURLWithPath: "/tmp/show.fieldwork")
        XCTAssertNil(model.missing)
        XCTAssertEqual(model.options, ConverterOptions())
    }

    func testShowOptionsMapToConverterOptions() {
        let model = DrillImportModel(source: drill)
        model.showDestination = URL(fileURLWithPath: "/tmp/show.fieldwork")
        model.allowApproximations = true
        model.flipX = true
        model.flipY = true
        model.pageMap = URL(fileURLWithPath: "/tmp/sets.json")
        model.stepsPerUnit = "1,6"
        let options = model.options
        XCTAssertTrue(options.allowApproximations && options.flipX && options.flipY)
        XCTAssertEqual(options.pageMap, model.pageMap)
        XCTAssertEqual(options.stepsPerUnit, 1.6)

        model.stepsPerUnit = "0"
        XCTAssertEqual(model.missing, "Steps per unit must be a number greater than 0.")
        model.stepsPerUnit = "lots"
        XCTAssertNotNil(model.missing)
        model.stepsPerUnit = " "
        XCTAssertNil(model.missing)
        XCTAssertNil(model.options.stepsPerUnit)
    }

    func testMusicXMLNeedsItsFilesBeforeConverting() {
        let model = DrillImportModel(source: drill)
        model.showDestination = URL(fileURLWithPath: "/tmp/show.fieldwork")
        model.exportMusicXML = true
        XCTAssertEqual(model.missing, "Choose where to save the MusicXML file.")
        model.musicXMLDestination = URL(fileURLWithPath: "/tmp/show.musicxml")
        XCTAssertNil(model.missing, "a recording is optional")

        model.audioOffset = "-0.25"
        XCTAssertEqual(model.options.audioOffset, -0.25)
        model.audioOffset = "soon"
        XCTAssertEqual(model.missing, "The audio offset must be a number of seconds.")
        model.audioOffset = ""

        model.clickCheck = true
        XCTAssertEqual(model.missing, "Choose the recording (.wav).")
        XCTAssertFalse(model.options.clickCheck, "never asks for a click check without a recording")
        model.audio = URL(fileURLWithPath: "/tmp/show.wav")
        XCTAssertEqual(model.missing, "Choose where to save the click check.")
        model.clickCheckDestination = URL(fileURLWithPath: "/tmp/check.wav")
        model.followAudio = true
        XCTAssertNil(model.missing)
        let options = model.options
        XCTAssertEqual(options.audio, model.audio)
        XCTAssertTrue(options.followAudio && options.clickCheck)
    }

    func testReadsTheCountTrackAudioOffset() {
        func xml(_ value: String) -> Data {
            Data("<identification><miscellaneous><miscellaneous-field name=\"audio-offset-seconds\">\(value)</miscellaneous-field></miscellaneous></identification>".utf8)
        }
        XCTAssertEqual(DrillImport.audioOffset(inMusicXML: xml("0.5270 (automatic)")), 0.527)
        XCTAssertEqual(DrillImport.audioOffset(inMusicXML: xml("-0.2500 (given)")), -0.25)
        XCTAssertEqual(DrillImport.audioOffset(inMusicXML: xml("0 (estimate not confident, not applied)")), 0)
        XCTAssertNil(DrillImport.audioOffset(inMusicXML: Data("<score-partwise/>".utf8)))

        let hits = DrillImport.alignmentHits(inMusicXML: Data("<miscellaneous-field name=\"alignment-beat-hits\">0.31 (chance 0.28)</miscellaneous-field>".utf8))
        XCTAssertEqual(hits?.rate, 0.31)
        XCTAssertEqual(hits?.chance, 0.28)
    }

    func testReportListsSavedFilesAndRetellsWarnings() {
        let diagnostics = [
            ConverterDiagnostic(severity: "warning", code: "alignment_not_confident",
                                message: "automatic alignment is not confident (best offset +0.527 s); count 0 is placed at the start of the audio. Check with --click-check, then pass --audio-offset or --follow-audio"),
            ConverterDiagnostic(severity: "warning", code: "measure_numbers_filled",
                                message: "measure(s) 228 were missing from every set and were inferred so the counts divide evenly"),
            ConverterDiagnostic(severity: "warning", code: "bar_lines_estimated",
                                message: "measures 254-259, 260-262 do not divide evenly into their counts; bar lines inside them are estimated"),
            ConverterDiagnostic(severity: "lossy", code: "set_beyond_timeline", message: "2 set(s) start after the last stored count and were dropped"),
            ConverterDiagnostic(severity: "info", code: "notes_moved_to_next_set", message: "1 text note(s) between sets were attached to the next set"),
            ConverterDiagnostic(severity: "warning", code: "something_new", message: "a future warning"),
        ]
        let report = ImportReport(sourceName: drill.lastPathComponent,
                                  savedFiles: [.init(role: "Count track", name: "show.musicxml")], diagnostics: diagnostics)
        XCTAssertEqual(report.sourceName, "show.3du")
        XCTAssertEqual(report.savedFiles.map(\.name), ["show.musicxml"])

        let notes = Dictionary(uniqueKeysWithValues: report.notes.map { ($0.code, $0) })
        XCTAssertTrue(notes["alignment_not_confident"]!.detail.contains("seconds into the recording"))
        XCTAssertFalse(notes["alignment_not_confident"]!.detail.contains("--"), "no command-line advice")
        XCTAssertEqual(notes["alignment_not_confident"]!.suggestedOffset, 0.527, "the guess can be applied from the report")
        XCTAssertNil(notes["measure_numbers_filled"]!.suggestedOffset)
        XCTAssertNil(report.realignment, "nothing to realign without a recording")
        XCTAssertTrue(notes["measure_numbers_filled"]!.detail.hasPrefix("Measure 228 wasn't"))
        XCTAssertTrue(notes["bar_lines_estimated"]!.detail.hasPrefix("Measures 254–259 and 260–262 don't"))
        XCTAssertEqual(notes["set_beyond_timeline"]!.detail, "2 sets start after the drill's last count, so they couldn't be imported.")
        XCTAssertTrue(notes["notes_moved_to_next_set"]!.detail.hasPrefix("1 text note sat"))
        XCTAssertEqual(notes["something_new"]!.detail, "A future warning.")
        XCTAssertTrue(report.technicalText.contains("[measure_numbers_filled] measure(s) 228"))

        XCTAssertEqual(report.needsAttention.first?.code, "set_beyond_timeline", "lost work comes first")
        XCTAssertEqual(report.forYourInformation.map(\.code), ["notes_moved_to_next_set"])
    }
}
