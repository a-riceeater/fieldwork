import Foundation
import DrillTiming
import DrillCore

/// User-meaningful document errors. Messages explain what happened and what
/// was (not) changed.
public enum DocumentError: Error, Equatable, CustomStringConvertible, Sendable {
    case notAFieldworkDocument(String)
    case newerFormat(major: Int, minor: Int)
    case newerSchema(Int)
    case corrupt(String)
    case missingAsset(String)
    case io(String)

    public var description: String {
        switch self {
        case .notAFieldworkDocument(let why): return "This file is not a Fieldwork show: \(why)"
        case .newerFormat(let major, let minor):
            return "This show was saved in format \(major).\(minor), which is newer than this version of Fieldwork supports. The file was not changed."
        case .newerSchema(let v): return "The show database uses schema \(v), which is newer than this version supports. The file was not changed."
        case .corrupt(let why): return "The show could not be read because it is damaged: \(why) The file was not changed."
        case .missingAsset(let path): return "The embedded file \(path) is missing or damaged."
        case .io(let why): return why
        }
    }
}

/// Replaceable product namespace for the container format.
public enum FormatIdentity {
    public static let formatIdentifier = "org.fieldwork.show"
    public static let fileExtension = "fieldwork"
    public static let uniformTypeIdentifier = "org.fieldwork.show"
    public static let major = 1
    public static let minor = 0
    public static let writer = "Fieldwork 0.1.0"
    /// Capabilities this reader understands.
    public static let knownCapabilities: Set<String> = ["drill.core.v1", "timing.anchors.v1", "media.audio.v1"]
}

public struct FormatVersion: Hashable, Codable, Sendable {
    public var major: Int
    public var minor: Int
}

public struct ManifestMember: Hashable, Codable, Sendable {
    public var path: String
    public var sha256: String
    public var bytes: Int64
}

public struct ManifestExtension: Hashable, Codable, Sendable {
    public var namespace: String
    public var required: Bool
}

/// `manifest.json`: identifies the container and lists every member with its hash.
public struct Manifest: Hashable, Codable, Sendable {
    public var format: String
    public var formatVersion: FormatVersion
    public var minReaderVersion: FormatVersion
    public var writer: String
    public var showID: String
    public var capabilities: [String]
    public var requiredCapabilities: [String]
    public var members: [ManifestMember]
    public var extensions: [ManifestExtension]
}

/// An opened document: the show plus embedded asset bytes and any opaque
/// extension members preserved for rewrite.
public struct ShowDocument: Sendable {
    public var show: Show
    /// Asset bytes keyed by archive path (`assets/<sha256>.<ext>`).
    public var assets: [String: Data]
    /// Unknown optional members under `extensions/`, preserved byte-for-byte.
    public var extensionMembers: [String: Data]
    public var extensions: [ManifestExtension]
    /// Set when the document must not be edited (unknown required capability).
    public var readOnlyReason: String?

    public init(show: Show, assets: [String: Data] = [:], extensionMembers: [String: Data] = [:], extensions: [ManifestExtension] = [], readOnlyReason: String? = nil) {
        self.show = show
        self.assets = assets
        self.extensionMembers = extensionMembers
        self.extensions = extensions
        self.readOnlyReason = readOnlyReason
    }

    /// Stores asset bytes, returning metadata keyed by content hash.
    public mutating func embed(_ data: Data, fileExtension: String, originalFilename: String, sampleRate: Double, frameCount: Int64,
                               channelCount: Int, assetID: MediaAssetID = MediaAssetID()) -> MediaAssetInfo {
        let info = MediaAssetInfo(id: assetID, sha256: SHA256.hex(data), fileExtension: fileExtension.lowercased(), originalFilename: originalFilename,
                                  byteCount: Int64(data.count), sampleRate: sampleRate, frameCount: frameCount, channelCount: channelCount)
        assets[info.archivePath] = data
        return info
    }
}

/// Encodes and decodes the `.fieldwork` ZIP container.
public enum DocumentCodec {
    public static func encode(_ document: ShowDocument) throws -> Data {
        try document.show.validate()
        let database = try ShowDatabase.encode(document.show, writer: FormatIdentity.writer)
        var members: [(path: String, data: Data)] = [("show.sqlite", database)]
        // Only assets referenced by the show are written; unreferenced bytes are dropped on save.
        for asset in document.show.mediaAssets {
            guard let data = document.assets[asset.archivePath] else { throw DocumentError.missingAsset(asset.archivePath) }
            guard SHA256.hex(data) == asset.sha256 else { throw DocumentError.missingAsset(asset.archivePath) }
            if !members.contains(where: { $0.path == asset.archivePath }) { members.append((asset.archivePath, data)) }
        }
        for (path, data) in document.extensionMembers.sorted(by: { $0.key < $1.key }) { members.append((path, data)) }
        let manifest = Manifest(
            format: FormatIdentity.formatIdentifier,
            formatVersion: FormatVersion(major: FormatIdentity.major, minor: FormatIdentity.minor),
            minReaderVersion: FormatVersion(major: 1, minor: 0),
            writer: FormatIdentity.writer,
            showID: document.show.id.description,
            capabilities: ["drill.core.v1", "timing.anchors.v1"] + (document.show.mediaAssets.isEmpty ? [] : ["media.audio.v1"]),
            requiredCapabilities: ["drill.core.v1"],
            members: members.map { ManifestMember(path: $0.path, sha256: SHA256.hex($0.data), bytes: Int64($0.data.count)) },
            extensions: document.extensions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        return try ZipArchive.write([("manifest.json", manifestData)] + members)
    }

    public static func decode(_ data: Data) throws -> ShowDocument {
        let members: [(path: String, data: Data)]
        do { members = try ZipArchive.read(data) } catch let error as ZipError {
            throw DocumentError.notAFieldworkDocument(error.message)
        }
        let byPath = Dictionary(uniqueKeysWithValues: members.map { ($0.path, $0.data) })
        guard let manifestData = byPath["manifest.json"] else { throw DocumentError.notAFieldworkDocument("manifest.json is missing.") }
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: manifestData) } catch {
            throw DocumentError.notAFieldworkDocument("manifest.json is malformed.")
        }
        guard manifest.format == FormatIdentity.formatIdentifier else {
            throw DocumentError.notAFieldworkDocument("unexpected format \(manifest.format).")
        }
        if manifest.formatVersion.major > FormatIdentity.major || manifest.minReaderVersion.major > FormatIdentity.major {
            throw DocumentError.newerFormat(major: manifest.formatVersion.major, minor: manifest.formatVersion.minor)
        }
        for member in manifest.members {
            guard let content = byPath[member.path], Int64(content.count) == member.bytes, SHA256.hex(content) == member.sha256 else {
                throw DocumentError.corrupt("\(member.path) does not match the manifest.")
            }
        }
        let listed = Set(manifest.members.map(\.path))
        for path in byPath.keys where path != "manifest.json" && !listed.contains(path) {
            throw DocumentError.corrupt("\(path) is not listed in the manifest.")
        }
        guard let database = byPath["show.sqlite"] else { throw DocumentError.corrupt("show.sqlite is missing.") }
        let show: Show
        do { show = try ShowDatabase.decode(database) } catch let error as DocumentError { throw error } catch {
            throw DocumentError.corrupt("\(error)")
        }
        var assets: [String: Data] = [:]
        for asset in show.mediaAssets {
            guard let bytes = byPath[asset.archivePath], SHA256.hex(bytes) == asset.sha256 else { throw DocumentError.missingAsset(asset.archivePath) }
            assets[asset.archivePath] = bytes
        }
        let extensionMembers = byPath.filter { $0.key.hasPrefix("extensions/") }
        var readOnly: String?
        let unknownRequired = manifest.requiredCapabilities.filter { !FormatIdentity.knownCapabilities.contains($0) }
            + manifest.extensions.filter { $0.required }.map(\.namespace)
        if !unknownRequired.isEmpty {
            readOnly = "This show requires features this version does not support (\(unknownRequired.joined(separator: ", "))). It is open read-only."
        }
        return ShowDocument(show: show, assets: assets, extensionMembers: extensionMembers, extensions: manifest.extensions, readOnlyReason: readOnly)
    }
}
