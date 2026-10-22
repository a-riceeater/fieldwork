import Foundation

/// Formats Fieldwork asks the bundled converter to write.
public enum ConverterOutputFormat: String, Sendable, CaseIterable {
    /// A Fieldwork show, opened afterwards by the normal document reader.
    case fieldwork
    /// An OpenMarch project (SQLite).
    case dots
    /// A MusicXML count track: measures, meters, tempos, rehearsal marks and sets.
    case musicxml

    public var fileExtension: String { rawValue }

    /// Leading bytes of every valid output.
    var signature: [UInt8] {
        switch self {
        case .fieldwork: Array("PK\u{3}\u{4}".utf8)
        case .dots: Array("SQLite format 3\u{0}".utf8)
        case .musicxml: Array("<?xml".utf8)
        }
    }
}

/// The converter options a person can choose when importing a drill. Each maps
/// to one converter flag. Output handling (`--json`, `--overwrite`) and logging
/// are the service's business, not the user's.
public struct ConverterOptions: Equatable, Sendable {
    /// Accept approximations, such as sets inferred from motion (`--allow-lossy`).
    /// Without it the converter refuses a conversion that is not faithful.
    public var allowApproximations = false
    /// A JSON list of `{"name", "start_count", "is_subset"}` that replaces the
    /// drill's sets (`--page-map`).
    public var pageMap: URL?
    /// Mirror the drill side to side (`--flip-x`).
    public var flipX = false
    /// Mirror the drill front to back (`--flip-y`).
    public var flipY = false
    /// Marching steps per source unit (`--steps-per-unit`); nil reads it from the drill.
    public var stepsPerUnit: Double?

    // MusicXML only; other formats ignore these, as the converter does.

    /// The show's `.wav` recording, to align the count track with (`--audio`).
    public var audio: URL?
    /// Audio time of count 0 in seconds (`--audio-offset`); nil aligns automatically.
    public var audioOffset: Double?
    /// Follow the recording beat by beat, for live performances (`--follow-audio`). Needs `audio`.
    public var followAudio = false
    /// Also produce the recording with a click on every aligned beat, to check
    /// the alignment by ear (`--click-check`). Needs `audio`.
    public var clickCheck = false

    public init() {}
}

/// One structured note from the converter. Its messages never contain
/// performer names, titles or other drill content, so they are safe to show.
public struct ConverterDiagnostic: Codable, Equatable, Sendable {
    /// `info`, `warning` or `lossy`.
    public var severity: String
    /// Stable identifier such as `curves_as_paths`.
    public var code: String
    public var message: String

    public init(severity: String, code: String, message: String) {
        self.severity = severity
        self.code = code
        self.message = message
    }

    public var isInformational: Bool { severity == "info" }
}

/// A finished conversion. Its temporary files are already deleted.
public struct ConverterResult: Sendable {
    public var format: ConverterOutputFormat
    /// The converted file's bytes.
    public var data: Data
    /// The click-check recording (`.wav`), when `ConverterOptions.clickCheck` asked for one.
    public var clickCheck: Data?
    public var diagnostics: [ConverterDiagnostic]

    /// Diagnostics worth showing to the user.
    public var warnings: [ConverterDiagnostic] { diagnostics.filter { !$0.isInformational } }
}

/// The converter's own reason for refusing or failing, from its JSON result.
public struct ConverterFailure: Equatable, Sendable {
    /// Process exit status (3 invalid input, 4 refused by the loss policy, 6 validation, 7 I/O).
    public var exitStatus: Int32
    /// Stable identifier such as `not_3du`.
    public var code: String
    public var message: String
    public var diagnostics: [ConverterDiagnostic]
}

public enum ConverterError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// The converter executable is not where this build of Fieldwork put it.
    case missingExecutable(String)
    case unreadableInput(String)
    /// Options that cannot work together, caught before the converter runs.
    case invalidOptions(String)
    case launchFailed(String)
    /// The converter ran and reported why it could not convert.
    case failed(ConverterFailure)
    /// The converter exited without the result Fieldwork expects.
    case malformedResult(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingExecutable: "Fieldwork’s .3du converter is missing."
        case .unreadableInput: "A file needed for the conversion could not be read."
        case .invalidOptions: "These conversion options cannot be used together."
        case .launchFailed: "The .3du converter could not be started."
        case .failed(let failure) where failure.exitStatus == 3: "This file is not a .3du drill that Fieldwork can import."
        case .failed(let failure) where failure.exitStatus == 4: "Importing this drill would approximate part of it."
        case .failed: "The drill could not be converted."
        case .malformedResult: "The .3du converter returned an unexpected result."
        case .cancelled: "The conversion was cancelled."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .missingExecutable(let path): "This copy of Fieldwork is incomplete. Reinstall Fieldwork. (Expected the converter at \(path).)"
        case .unreadableInput(let detail), .invalidOptions(let detail), .launchFailed(let detail): detail
        case .failed(let failure):
            ([failure.message] + failure.diagnostics.filter { !$0.isInformational }.map(\.message)).joined(separator: "\n")
                + (failure.exitStatus == 4 ? "\nTurn on “Accept approximations” to convert anyway." : "")
        case .malformedResult(let detail): "\(detail)\nThe bundled converter may not match this version of Fieldwork."
        case .cancelled: nil
        }
    }

    public var description: String { [errorDescription, recoverySuggestion].compactMap { $0 }.joined(separator: " ") }
}

/// Runs the converter executable that ships inside Fieldwork. Each call works in
/// its own temporary directory, which is deleted when the call returns: the
/// source drill is copied in first, so the converter only ever touches files
/// Fieldwork owns (and, when sandboxed, it inherits Fieldwork's sandbox).
///
/// Arguments are passed as a list, never through a shell, and the converter's
/// `--json` result on stdout is the only thing parsed; stderr is kept for error
/// details. Cancelling the calling task terminates the converter.
public struct ThreeDUConverterService: Sendable {
    /// The CLI contract this code speaks: `convert <in> --format <f> --output <out> --json`,
    /// the `{"ok", "result" | "error"}` envelope and the documented exit codes.
    /// `scripts/build-converter.sh` records the same number in the build info.
    public static let interface = 1

    public static var defaultWorkRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Fieldwork-Conversions", isDirectory: true)
    }

    public let executableURL: URL
    public let workRoot: URL

    public init(executableURL: URL = ConverterLocator.bundledExecutable(), workRoot: URL = ThreeDUConverterService.defaultWorkRoot) {
        self.executableURL = executableURL
        self.workRoot = workRoot
    }

    /// Converts a `.3du` drill and returns the converted file's bytes. The drill,
    /// page map and recording are copied into the work directory first, and
    /// every output is written there; the caller saves the bytes where the user chose.
    public func convert(_ input: URL, to format: ConverterOutputFormat = .fieldwork, options: ConverterOptions = ConverterOptions()) async throws -> ConverterResult {
        try checkExecutable()
        let musicXML = format == .musicxml
        try Self.validate(options, musicXML: musicXML)
        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }

        let output = work.appendingPathComponent("output.\(format.fileExtension)")
        let clickCheck = work.appendingPathComponent("click-check.wav")
        var arguments = ["convert", try copy(input, into: work, as: "input.3du"), "--format", format.rawValue, "--output", Self.path(output), "--json"]
        if options.allowApproximations { arguments.append("--allow-lossy") }
        if let pageMap = options.pageMap { arguments += ["--page-map", try copy(pageMap, into: work, as: "page-map.json")] }
        if options.flipX { arguments.append("--flip-x") }
        if options.flipY { arguments.append("--flip-y") }
        if let steps = options.stepsPerUnit { arguments += ["--steps-per-unit", String(steps)] }
        if musicXML {
            if let audio = options.audio { arguments += ["--audio", try copy(audio, into: work, as: "audio.wav")] }
            if let offset = options.audioOffset { arguments += ["--audio-offset", String(offset)] }
            if options.followAudio { arguments.append("--follow-audio") }
            if options.clickCheck { arguments += ["--click-check", Self.path(clickCheck)] }
        }
        let run = try await self.run(arguments, in: work)

        let envelope = try? JSONDecoder().decode(Envelope.self, from: run.stdout)
        guard let envelope else { throw ConverterError.malformedResult("\(run.exitSummary) without a JSON result.\(run.stderrSummary)") }
        guard envelope.ok, run.status == 0 else {
            guard let error = envelope.error, run.status != 0 else {
                throw ConverterError.malformedResult("The converter exited with status \(run.status) but reported \(envelope.ok ? "success" : "failure").\(run.stderrSummary)")
            }
            throw ConverterError.failed(ConverterFailure(exitStatus: run.status, code: error.code, message: error.message, diagnostics: error.diagnostics ?? []))
        }
        guard let data = try? Data(contentsOf: output), data.starts(with: format.signature) else {
            throw ConverterError.malformedResult("The converter reported success, but did not write a valid .\(format.fileExtension) file.")
        }
        var click: Data?
        if musicXML && options.clickCheck {
            guard let wav = try? Data(contentsOf: clickCheck), wav.starts(with: Array("RIFF".utf8)) else {
                throw ConverterError.malformedResult("The converter reported success, but did not write the click-check recording.")
            }
            click = wav
        }
        return ConverterResult(format: format, data: data, clickCheck: click, diagnostics: envelope.result?.diagnostics ?? [])
    }

    /// Rejects what the converter would refuse with a usage error (and no JSON).
    static func validate(_ options: ConverterOptions, musicXML: Bool) throws {
        if let steps = options.stepsPerUnit, !(steps.isFinite && steps > 0) {
            throw ConverterError.invalidOptions("Steps per unit must be a number greater than 0.")
        }
        guard musicXML else { return }
        if let offset = options.audioOffset, !offset.isFinite {
            throw ConverterError.invalidOptions("The audio offset must be a number of seconds.")
        }
        if options.audio == nil && (options.followAudio || options.clickCheck) {
            throw ConverterError.invalidOptions("Following the recording and the click check need a recording (.wav).")
        }
    }

    /// Copies a file the user chose into the work directory and returns the copy's path.
    private func copy(_ url: URL, into work: URL, as name: String) throws -> String {
        let copy = work.appendingPathComponent(name)
        do { try FileManager.default.copyItem(at: url, to: copy) } catch {
            throw ConverterError.unreadableInput("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        return Self.path(copy)
    }

    /// The converter's version, for example `0.1.0`, as it reports it.
    public func version() async throws -> String {
        try checkExecutable()
        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let run = try await self.run(["--version"], in: work)
        let text = String(decoding: run.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard run.status == 0, let version = text.split(separator: " ").last, !version.isEmpty else {
            throw ConverterError.malformedResult("`--version`: \(run.exitSummary).\(run.stderrSummary)")
        }
        return String(version)
    }

    // MARK: Running the process

    private struct Envelope: Decodable {
        struct Success: Decodable {
            var output: String?
            var diagnostics: [ConverterDiagnostic]?
        }
        struct Failure: Decodable {
            var code: String
            var message: String
            var diagnostics: [ConverterDiagnostic]?
        }
        var ok: Bool
        var result: Success?
        var error: Failure?
    }

    struct RunOutput {
        var status: Int32
        /// Only a hint: Windows reports exit status 3 (also abort's) as a signal,
        /// so a JSON result always wins over it.
        var signaled: Bool
        var stdout: Data
        var stderr: Data

        var exitSummary: String {
            signaled ? "The converter stopped unexpectedly (signal \(status))" : "The converter exited with status \(status)"
        }

        /// The end of stderr, for error details (it never holds drill content).
        var stderrSummary: String {
            let text = String(decoding: stderr.suffix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "" : "\n\(text)"
        }
    }

    private func checkExecutable() throws {
        #if os(Windows)
        let found = FileManager.default.fileExists(atPath: Self.path(executableURL))
        #else
        let found = FileManager.default.isExecutableFile(atPath: Self.path(executableURL))
        #endif
        guard found else { throw ConverterError.missingExecutable(Self.path(executableURL)) }
    }

    /// A fresh directory under `workRoot`. Directories a crash left behind are
    /// removed once they are a day old.
    private func makeWorkDirectory() throws -> URL {
        let files = FileManager.default
        let stale = Date().addingTimeInterval(-86_400)
        for old in (try? files.contentsOfDirectory(at: workRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let modified = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < stale {
                try? files.removeItem(at: old)
            }
        }
        let work = workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try files.createDirectory(at: work, withIntermediateDirectories: true) } catch {
            throw ConverterError.launchFailed("Could not create a temporary folder: \(error.localizedDescription)")
        }
        return work
    }

    /// Runs the converter with stdout and stderr captured to files in `directory`
    /// (no pipe can fill up and stall it).
    func run(_ arguments: [String], in directory: URL) async throws -> RunOutput {
        if Task.isCancelled { throw ConverterError.cancelled }
        let stdoutURL = directory.appendingPathComponent("stdout.json")
        let stderrURL = directory.appendingPathComponent("stderr.txt")
        let process = Process()
        do {
            _ = FileManager.default.createFile(atPath: Self.path(stdoutURL), contents: nil)
            _ = FileManager.default.createFile(atPath: Self.path(stderrURL), contents: nil)
            let stdout = try FileHandle(forWritingTo: stdoutURL)
            let stderr = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdout.close()
                try? stderr.close()
            }
            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout
            process.standardError = stderr
            let launch = Launch(process)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    launch.start(continuation)
                }
            } onCancel: {
                launch.cancel()
            }
            if launch.wasCancelled { throw ConverterError.cancelled }
        } catch let error as ConverterError {
            throw error
        } catch {
            throw ConverterError.launchFailed(error.localizedDescription)
        }
        return RunOutput(status: process.terminationStatus, signaled: process.terminationReason == .uncaughtSignal,
                         stdout: (try? Data(contentsOf: stdoutURL)) ?? Data(),
                         stderr: (try? Data(contentsOf: stderrURL)) ?? Data())
    }

    /// Starts the process unless the task was already cancelled, and terminates it
    /// on cancellation. The lock orders `start` and `cancel`, which can race.
    private final class Launch: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var cancelled = false

        init(_ process: Process) { self.process = process }

        func start(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { return continuation.resume(throwing: ConverterError.cancelled) }
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: ConverterError.launchFailed(error.localizedDescription))
            }
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            if process.isRunning { process.terminate() }
        }

        var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    /// The native file-system path (no leading slash before a Windows drive letter).
    static func path(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { String(cString: $0!) }
    }
}
