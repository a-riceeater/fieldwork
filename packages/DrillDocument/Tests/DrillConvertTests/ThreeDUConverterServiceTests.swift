import XCTest
import DrillCore
import DrillDocument
@testable import DrillConvert

/// Runs the real converter built by `scripts/build-converter.sh --fixtures`, on
/// the converter's own synthetic show (never a real drill). Tests that need the
/// build skip without it, unless FIELDWORK_REQUIRE_CONVERTER=1 (as in CI).
final class ThreeDUConverterServiceTests: XCTestCase {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let buildDirectory = repoRoot.appendingPathComponent("build/converter", isDirectory: true)

    private var workRoot: URL!

    override func setUpWithError() throws {
        workRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FieldworkConverterTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workRoot)
    }

    private func builtConverter() throws -> URL {
        #if os(Windows)
        let name = "3du-converter.exe"
        #else
        let name = "3du-converter"
        #endif
        let url = ProcessInfo.processInfo.environment["FIELDWORK_CONVERTER"].map { URL(fileURLWithPath: $0) }
            ?? Self.buildDirectory.appendingPathComponent(name)
        return try requireFile(url, "the converter (run scripts/build-converter.sh --fixtures)")
    }

    private func syntheticDrill() throws -> URL {
        try requireFile(Self.buildDirectory.appendingPathComponent("fixtures/synthetic.3du"), "the synthetic fixture (run scripts/build-converter.sh --fixtures)")
    }

    private func requireFile(_ url: URL, _ what: String) throws -> URL {
        if FileManager.default.fileExists(atPath: ThreeDUConverterService.path(url)) { return url }
        if ProcessInfo.processInfo.environment["FIELDWORK_REQUIRE_CONVERTER"] == "1" {
            XCTFail("Missing \(what) at \(url.path)")
        }
        throw XCTSkip("Missing \(what)")
    }

    /// Nothing may be left in the work root after a call returns.
    private func assertWorkRootIsEmpty(file: StaticString = #filePath, line: UInt = #line) {
        let left = (try? FileManager.default.contentsOfDirectory(atPath: ThreeDUConverterService.path(workRoot))) ?? []
        XCTAssertEqual(left, [], "temporary conversion files were not cleaned up", file: file, line: line)
    }

    private func failure(of work: () async throws -> some Any) async -> ConverterError? {
        do {
            _ = try await work()
            return nil
        } catch {
            return error as? ConverterError
        }
    }

    func testConvertsTheSyntheticDrillToAShowFieldworkOpens() async throws {
        let service = ThreeDUConverterService(executableURL: try builtConverter(), workRoot: workRoot)
        let result = try await service.convert(try syntheticDrill())
        XCTAssertEqual(result.format, .fieldwork)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "curves_as_paths" })
        XCTAssertEqual(result.warnings, [])

        let document = try DocumentCodec.decode(result.data)
        XCTAssertNil(document.readOnlyReason)
        XCTAssertFalse(document.show.performers.isEmpty)
        XCTAssertFalse(document.show.sets.isEmpty)
        assertWorkRootIsEmpty()
    }

    func testConvertsToOpenMarchDots() async throws {
        let service = ThreeDUConverterService(executableURL: try builtConverter(), workRoot: workRoot)
        let result = try await service.convert(try syntheticDrill(), to: .dots)
        XCTAssertTrue(result.data.starts(with: Array("SQLite format 3".utf8)))
        assertWorkRootIsEmpty()
    }

    func testMusicXMLAlignsWithARecordingAndReturnsTheClickCheck() async throws {
        let service = ThreeDUConverterService(executableURL: try builtConverter(), workRoot: workRoot)
        let recording = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID().uuidString).wav")
        try Self.syntheticRecording(seconds: 40).write(to: recording)
        defer { try? FileManager.default.removeItem(at: recording) }
        var options = ConverterOptions()
        options.audio = recording
        options.audioOffset = 0.5
        options.clickCheck = true

        let result = try await service.convert(try syntheticDrill(), to: .musicxml, options: options)
        let xml = String(decoding: result.data, as: UTF8.self)
        XCTAssertTrue(xml.contains("<score-partwise"))
        XCTAssertTrue(xml.contains("0.5000 (given)"), "the given audio offset is recorded in the score")
        let click = try XCTUnwrap(result.clickCheck)
        XCTAssertTrue(click.starts(with: Array("RIFF".utf8)))
        assertWorkRootIsEmpty()
    }

    func testMusicXMLWithoutARecordingHasNoClickCheck() async throws {
        let service = ThreeDUConverterService(executableURL: try builtConverter(), workRoot: workRoot)
        let result = try await service.convert(try syntheticDrill(), to: .musicxml)
        XCTAssertTrue(String(decoding: result.data, as: UTF8.self).contains("<score-partwise"))
        XCTAssertNil(result.clickCheck)
    }

    func testFlipOptionsMirrorTheDrill() async throws {
        let service = ThreeDUConverterService(executableURL: try builtConverter(), workRoot: workRoot)
        let drill = try syntheticDrill()
        var flipped = ConverterOptions()
        flipped.flipX = true
        flipped.flipY = true
        let plain = try DocumentCodec.decode(try await service.convert(drill).data).show
        let mirrored = try DocumentCodec.decode(try await service.convert(drill, options: flipped).data).show
        let a = try SceneEvaluator(show: plain, movementID: plain.movements[0].id).evaluate(pulse: 0).performers
        let b = try SceneEvaluator(show: mirrored, movementID: mirrored.movements[0].id).evaluate(pulse: 0).performers
        XCTAssertEqual(a.count, b.count)
        XCTAssertTrue(a.contains { abs($0.x) > 0.01 })
        for (p, q) in zip(a, b) {
            XCTAssertEqual(q.x, -p.x, accuracy: 1e-6)
            XCTAssertEqual(q.y, -p.y, accuracy: 1e-6)
        }
    }

    func testRejectsOptionsTheConverterCannotUse() async throws {
        let service = ThreeDUConverterService(executableURL: try builtConverter(), workRoot: workRoot)
        let drill = try syntheticDrill()
        var follow = ConverterOptions()
        follow.followAudio = true
        guard case .invalidOptions = await failure(of: { try await service.convert(drill, to: .musicxml, options: follow) }) else {
            return XCTFail("following the recording without one was accepted")
        }
        var steps = ConverterOptions()
        steps.stepsPerUnit = 0
        guard case .invalidOptions = await failure(of: { try await service.convert(drill, options: steps) }) else {
            return XCTFail("0 steps per unit was accepted")
        }
        // Audio options do not apply to a show, so they are ignored there, as the converter does.
        _ = try await service.convert(drill, options: follow)
        assertWorkRootIsEmpty()
    }

    /// A mono 16-bit recording of clicks every half second (no real music).
    static func syntheticRecording(seconds: Int, rate: Int = 8000) -> Data {
        var samples = [Int16](repeating: 0, count: seconds * rate)
        for start in stride(from: 0, to: samples.count, by: rate / 2) {
            for i in 0..<min(80, samples.count - start) { samples[start + i] = i.isMultiple(of: 2) ? 12000 : -12000 }
        }
        func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
        let body = samples.flatMap { le($0) }
        var wav = Array("RIFF".utf8) + le(UInt32(36 + body.count)) + Array("WAVEfmt ".utf8)
        wav += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1)) + le(UInt32(rate)) + le(UInt32(rate * 2)) + le(UInt16(2)) + le(UInt16(16))
        wav += Array("data".utf8) + le(UInt32(body.count)) + body
        return Data(wav)
    }

    func testReportsTheConvertersReasonForAFileThatIsNotADrill() async throws {
        let service = ThreeDUConverterService(executableURL: try builtConverter(), workRoot: workRoot)
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-drill-\(UUID().uuidString).3du")
        try Data("not a drill".utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }

        let error = await failure { try await service.convert(input) }
        guard case .failed(let reason) = error else { return XCTFail("expected a converter failure, got \(String(describing: error))") }
        XCTAssertEqual(reason.exitStatus, 3)
        XCTAssertEqual(reason.code, "not_3du")
        XCTAssertEqual(error?.errorDescription, "This file is not a .3du drill that Fieldwork can import.")
        assertWorkRootIsEmpty()
    }

    func testReportsAMissingExecutable() async throws {
        let missing = workRoot.appendingPathComponent("no-such-converter")
        let service = ThreeDUConverterService(executableURL: missing, workRoot: workRoot)
        let error = await failure { try await service.convert(missing) }
        XCTAssertEqual(error, .missingExecutable(ThreeDUConverterService.path(missing)))
        XCTAssertNotNil(error?.recoverySuggestion)
    }

    func testReportsAMissingInput() async throws {
        let service = ThreeDUConverterService(executableURL: try builtConverter(), workRoot: workRoot)
        let error = await failure { try await service.convert(self.workRoot.appendingPathComponent("gone.3du")) }
        guard case .unreadableInput = error else { return XCTFail("expected unreadableInput, got \(String(describing: error))") }
        assertWorkRootIsEmpty()
    }

    /// Any executable that does not answer with the JSON envelope.
    func testRejectsAResultWithoutTheJSONEnvelope() async throws {
        #if os(Windows)
        let other = URL(fileURLWithPath: "C:\\Windows\\System32\\where.exe")
        #else
        let other = URL(fileURLWithPath: "/bin/echo")
        #endif
        let service = ThreeDUConverterService(executableURL: try requireFile(other, "a system tool"), workRoot: workRoot)
        let error = await failure { try await service.convert(try self.syntheticDrill()) }
        guard case .malformedResult = error else { return XCTFail("expected malformedResult, got \(String(describing: error))") }
        assertWorkRootIsEmpty()
    }

    func testACancelledTaskDoesNotRunTheConverter() async throws {
        let service = ThreeDUConverterService(executableURL: try builtConverter(), workRoot: workRoot)
        let drill = try syntheticDrill()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.convert(drill)
        }
        let error = await failure { try await task.value }
        XCTAssertEqual(error, .cancelled)
        assertWorkRootIsEmpty()
    }

    func testVersionAndBuildInfoAgree() async throws {
        let service = ThreeDUConverterService(executableURL: try builtConverter(), workRoot: workRoot)
        let version = try await service.version()
        let info = try XCTUnwrap(ConverterBuildInfo(contentsOf: Self.buildDirectory.appendingPathComponent("\(ConverterLocator.buildInfoName).json")))
        XCTAssertEqual(info.version, version)
        XCTAssertEqual(info.interface, ThreeDUConverterService.interface)
        XCTAssertEqual(info.sourceCommit.count, 40)
        XCTAssertTrue(info.summary.hasPrefix("3du-converter \(version) ("))
    }
}
