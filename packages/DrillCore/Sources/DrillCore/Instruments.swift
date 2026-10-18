import Foundation

/// A common marching section with the drill letter used for its labels
/// (T1, T2…). Letters follow the Pyware/UDB convention; only F (flute) and
/// T (trumpet) are confirmed by published Pyware/UDB documentation, so the
/// rest should be checked against a real UDB roster.
public struct InstrumentPreset: Hashable, Sendable, Identifiable {
    public enum Family: String, CaseIterable, Sendable {
        case woodwinds, brass, percussion, colorGuard

        public var displayName: String {
            switch self {
            case .woodwinds: return "Woodwinds"
            case .brass: return "Brass"
            case .percussion: return "Percussion"
            case .colorGuard: return "Color Guard"
            }
        }
    }

    public var name: String
    public var prefix: String
    public var family: Family
    public var id: String { name }

    public init(name: String, prefix: String, family: Family) {
        self.name = name
        self.prefix = prefix
        self.family = family
    }

    public static let all: [InstrumentPreset] = [
        .init(name: "Piccolo", prefix: "P", family: .woodwinds),
        .init(name: "Flute", prefix: "F", family: .woodwinds),
        .init(name: "Clarinet", prefix: "C", family: .woodwinds),
        .init(name: "Bass Clarinet", prefix: "L", family: .woodwinds),
        .init(name: "Alto Saxophone", prefix: "A", family: .woodwinds),
        .init(name: "Tenor Saxophone", prefix: "N", family: .woodwinds),
        .init(name: "Baritone Saxophone", prefix: "X", family: .woodwinds),
        .init(name: "Trumpet", prefix: "T", family: .brass),
        .init(name: "Mellophone", prefix: "M", family: .brass),
        .init(name: "French Horn", prefix: "H", family: .brass),
        .init(name: "Trombone", prefix: "B", family: .brass),
        .init(name: "Baritone", prefix: "E", family: .brass),
        .init(name: "Tuba", prefix: "U", family: .brass),
        .init(name: "Snare Drum", prefix: "S", family: .percussion),
        .init(name: "Tenor Drums", prefix: "Q", family: .percussion),
        .init(name: "Bass Drum", prefix: "D", family: .percussion),
        .init(name: "Cymbals", prefix: "Y", family: .percussion),
        .init(name: "Front Ensemble", prefix: "K", family: .percussion),
        .init(name: "Color Guard", prefix: "G", family: .colorGuard),
    ]

    public static func named(_ name: String) -> InstrumentPreset? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return all.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    public static func family(_ family: Family) -> [InstrumentPreset] {
        all.filter { $0.family == family }
    }
}
