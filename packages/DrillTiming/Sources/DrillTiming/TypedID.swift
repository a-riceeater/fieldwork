import Foundation

/// A strongly typed, stable identifier. The phantom `Tag` keeps performer,
/// set, event and anchor IDs from being mixed up at compile time.
public struct TypedID<Tag>: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let uuid: UUID

    public init() { uuid = UUID() }
    public init(uuid: UUID) { self.uuid = uuid }
    public init?(_ string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.uuid = uuid
    }

    public var description: String { uuid.uuidString }

    public static func < (lhs: TypedID, rhs: TypedID) -> Bool {
        lhs.uuid.uuidString < rhs.uuid.uuidString
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let uuid = UUID(uuidString: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid UUID \(string)")
        }
        self.uuid = uuid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid.uuidString)
    }
}

public enum EventTag {}
public enum MeasureTag {}
public enum AnchorTag {}
public enum MediaAssetTag {}

public typealias EventID = TypedID<EventTag>
public typealias MeasureID = TypedID<MeasureTag>
public typealias AnchorID = TypedID<AnchorTag>
public typealias MediaAssetID = TypedID<MediaAssetTag>
