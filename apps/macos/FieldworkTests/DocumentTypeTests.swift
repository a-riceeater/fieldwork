import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import Fieldwork

/// Guards the Info.plist document declaration: if the class name or type
/// drifts, macOS says it "cannot open files in the Fieldwork Show format" and
/// Save As offers a generic data file without the .fieldwork extension.
final class DocumentTypeTests: XCTestCase {
    @MainActor
    func testShowTypeMapsToTheDocumentClassAndExtension() throws {
        let controller = NSDocumentController.shared
        let type = try XCTUnwrap(controller.defaultType, "Info.plist declares no document type")
        XCTAssertTrue(controller.documentClass(forType: type) == FieldworkDocument.self, "NSDocumentClass does not resolve to FieldworkDocument")
        XCTAssertTrue(FieldworkDocument.readableTypes.contains(type))
        XCTAssertTrue(FieldworkDocument.writableTypes.contains(type))
        XCTAssertEqual(UTType(type)?.preferredFilenameExtension, "fieldwork")
        XCTAssertEqual(UTType(filenameExtension: "fieldwork")?.identifier, type)

        let document = FieldworkDocument()
        document.fileType = type
        XCTAssertEqual(document.fileNameExtension(forType: type, saveOperation: .saveAsOperation), "fieldwork")
    }
}
