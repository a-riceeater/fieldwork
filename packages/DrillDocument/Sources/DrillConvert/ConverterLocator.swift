import Foundation

/// Where each platform's app bundle keeps the converter. This is the only
/// platform-specific part of the integration; the CLI and the service are the
/// same everywhere.
public enum ConverterLocator {
    public static let executableName = "3du-converter"
    /// `3du-converter-build.json`, written by `scripts/build-converter.sh`.
    public static let buildInfoName = "3du-converter-build"

    /// macOS: `Fieldwork.app/Contents/MacOS/3du-converter`, beside the app's own
    /// executable. Windows: `3du-converter.exe` beside the app's `.exe`.
    public static func bundledExecutable(in bundle: Bundle = .main) -> URL {
        #if os(Windows)
        let directory = bundle.executableURL?.deletingLastPathComponent() ?? bundle.bundleURL
        return directory.appendingPathComponent(executableName + ".exe")
        #else
        return bundle.url(forAuxiliaryExecutable: executableName)
            ?? bundle.bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(executableName)
        #endif
    }

    /// The version and source commit of the bundled converter, or nil when the
    /// build info is missing or unreadable.
    public static func buildInfo(in bundle: Bundle = .main) -> ConverterBuildInfo? {
        guard let url = bundle.url(forResource: buildInfoName, withExtension: "json") else { return nil }
        return ConverterBuildInfo(contentsOf: url)
    }
}

/// What `scripts/build-converter.sh` records about the converter it built.
public struct ConverterBuildInfo: Codable, Equatable, Sendable {
    public var name: String
    public var version: String
    /// The CLI contract number; matches `ThreeDUConverterService.interface`.
    public var interface: Int
    /// The `vendor/3du-converter` commit the binary was built from.
    public var sourceCommit: String
    /// True when the source had uncommitted changes (never in a release).
    public var sourceDirty: Bool
    public var architectures: [String]

    public init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url), let info = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = info
    }

    /// "3du-converter 0.1.0 (2cb3d4ce6990)".
    public var summary: String {
        "\(name) \(version) (\(sourceCommit.prefix(12))\(sourceDirty ? ", modified" : ""))"
    }
}
