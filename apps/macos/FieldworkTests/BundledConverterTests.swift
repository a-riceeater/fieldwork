import XCTest
import DrillConvert
@testable import Fieldwork

/// The app bundle the tests run in must carry a working converter in
/// Contents/MacOS, with build info that matches it.
final class BundledConverterTests: XCTestCase {
    func testConverterIsEmbeddedAndRuns() async throws {
        let executable = ConverterLocator.bundledExecutable()
        XCTAssertEqual(executable.deletingLastPathComponent().lastPathComponent, "MacOS")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), "missing \(executable.path)")
        let info = try XCTUnwrap(ConverterLocator.buildInfo(), "3du-converter-build.json is not in Resources")
        XCTAssertEqual(info.interface, ThreeDUConverterService.interface)
        let version = try await ThreeDUConverterService().version()
        XCTAssertEqual(version, info.version)
    }

    /// A broken file produces the converter's own reason, shown with the converter build.
    func testFailedImportExplainsTheReason() async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-drill-\(UUID().uuidString).3du")
        try Data("not a drill".utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        do {
            _ = try await ThreeDUConverterService().convert(input)
            XCTFail("a file that is not a drill converted")
        } catch {
            let text = DrillImport.explain(error)
            XCTAssertTrue(text.hasPrefix("This file is not a .3du drill that Fieldwork can import."), text)
            XCTAssertTrue(text.contains("Converter: 3du-converter "), text)
        }
    }
}
