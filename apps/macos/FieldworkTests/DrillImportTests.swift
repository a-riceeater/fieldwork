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

    func testNoticeListsSavedFilesAndWarnings() {
        let notice = DrillImport.notice(source: drill, warnings: [ConverterDiagnostic(severity: "warning", code: "alignment_not_confident", message: "alignment is not confident")],
                                        extras: ["Saved the count track as “show.musicxml”."])
        XCTAssertTrue(notice.hasPrefix("Converted from “show.3du”."))
        XCTAssertTrue(notice.contains("show.musicxml"))
        XCTAssertTrue(notice.hasSuffix("Notes: alignment is not confident"))
    }
}
