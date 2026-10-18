import Foundation

/// A user-facing choice offered when a timing edit contradicts existing constraints.
public enum TimingResolution: Hashable, Codable, Sendable {
    /// Replace an existing anchor with the new one.
    case replaceAnchor(AnchorID)
    /// Remove an anchor so the edit can apply.
    case releaseAnchor(AnchorID)
    /// Keep the pins and refit elastic durations between them.
    case fitBetweenAnchors
    case cancel
}

/// A timing edit that cannot be applied as requested. The caller must pick
/// one of `options` (or cancel); nothing is changed silently.
public struct TimingEditConflict: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public var options: [TimingResolution]
    public var anchors: [AnchorID]
    public var description: String { message }
}

public struct TimingEditOutcome: Sendable {
    public var track: TimingTrack
    public var report: FitReport
}

/// Validated timing operations. Each returns a new track plus the fit report,
/// or throws `TimingEditConflict` describing the available resolutions.
public enum TimingEditor {
    /// Adds an anchor ("Align here"). An anchor at an already pinned position or one
    /// that contradicts existing pins produces options instead of a change.
    public static func addAnchor(_ anchor: AudioAnchor, to track: TimingTrack, resolution: TimingResolution? = nil) throws -> TimingEditOutcome {
        let map = try TimingMap(track: track, assetID: anchor.assetID)
        if resolution == .cancel { return TimingEditOutcome(track: track, report: map.report) }
        var next = track
        var anchor = anchor
        anchor.cursor = try map.canonical(anchor.cursor)
        switch resolution {
        case .replaceAnchor(let id)?, .releaseAnchor(let id)?:
            next.anchors.removeAll { $0.id == id }
        default:
            break
        }
        for existing in next.anchors where existing.assetID == anchor.assetID {
            if try map.compare(existing.cursor, anchor.cursor) == .orderedSame {
                let position = try map.musicalPosition(at: anchor.cursor).label
                throw TimingEditConflict(message: "\(position) is already pinned at \(TimeFormat.clock(existing.seconds)). Replace that pin or cancel.",
                                         options: [.replaceAnchor(existing.id), .cancel], anchors: [existing.id])
            }
        }
        next.anchors.append(anchor)
        return try validate(next, assetID: anchor.assetID, changedAnchor: anchor.id)
    }

    /// Moves an anchor to a new source sample frame (drag or typed milliseconds).
    public static func moveAnchor(_ id: AnchorID, toSampleFrame frame: Int64, in track: TimingTrack) throws -> TimingEditOutcome {
        var next = track
        guard let i = next.anchors.firstIndex(where: { $0.id == id }) else { throw TimingError("Unknown anchor.") }
        next.anchors[i].sampleFrame = frame
        return try validate(next, assetID: next.anchors[i].assetID, changedAnchor: nil)
    }

    public static func removeAnchor(_ id: AnchorID, from track: TimingTrack) throws -> TimingEditOutcome {
        var next = track
        guard let anchor = next.anchors.first(where: { $0.id == id }) else { throw TimingError("Unknown anchor.") }
        next.anchors.removeAll { $0.id == id }
        let map = try TimingMap(track: next, assetID: anchor.assetID)
        return TimingEditOutcome(track: next, report: map.report)
    }

    /// Sets a constant tempo for a measure range. In Preserve Notated Tempo mode an
    /// edit inside a pinned interval is a conflict offering release/fit/cancel.
    public static func setTempo(measures range: ClosedRange<Int>, bpm: Double, in track: TimingTrack, assetID: MediaAssetID?,
                                resolution: TimingResolution? = nil) throws -> TimingEditOutcome {
        if resolution == .cancel {
            return TimingEditOutcome(track: track, report: try TimingMap(track: track, assetID: assetID).report)
        }
        var next = track
        if case .releaseAnchor(let id)? = resolution { next.anchors.removeAll { $0.id == id } }
        if next.fitMode == .preserveNotatedTempo, resolution == nil, let assetID {
            let bounding = try pinnedAnchors(around: range, in: next, assetID: assetID)
            if !bounding.isEmpty {
                let map = try TimingMap(track: next, assetID: assetID)
                var labels: [String] = []
                for id in bounding {
                    let a = next.anchors.first { $0.id == id }!
                    labels.append("\(try map.musicalPosition(at: a.cursor).label) @ \(TimeFormat.clock(a.seconds))")
                }
                throw TimingEditConflict(
                    message: "These measures lie between audio pins (\(labels.joined(separator: ", "))). A new notated tempo cannot keep both pins. Release a pin, fit the interval between pins, or cancel.",
                    options: bounding.map { .releaseAnchor($0) } + [.fitBetweenAnchors, .cancel], anchors: bounding)
            }
        }
        try next.setTempo(measures: range, bpm: bpm)
        return try validate(next, assetID: assetID, changedAnchor: nil)
    }

    /// Anchors bounding any pinned interval that overlaps the measure range.
    public static func pinnedAnchors(around range: ClosedRange<Int>, in track: TimingTrack, assetID: MediaAssetID) throws -> [AnchorID] {
        let map = try TimingMap(track: track, assetID: nil)
        let measureIDs = Set(track.measures[range].map(\.id))
        let changed = track.events.filter { measureIDs.contains($0.measureID) }
        guard let first = changed.first, let last = changed.last else { return [] }
        let lo = try map.baselineSeconds(at: TimelineCursor(eventID: first.id))
        let hi = try map.baselineSeconds(at: TimelineCursor(eventID: last.id, fraction: .one))
        var anchors: [(AudioAnchor, Double)] = []
        for anchor in track.anchors where anchor.assetID == assetID {
            anchors.append((anchor, try map.baselineSeconds(at: anchor.cursor)))
        }
        anchors.sort { $0.1 < $1.1 }
        var result: [AnchorID] = []
        for (a, b) in zip(anchors, anchors.dropFirst()) where a.1 < hi && b.1 > lo {
            for id in [a.0.id, b.0.id] where !result.contains(id) { result.append(id) }
        }
        return result
    }

    /// `changedAnchor` is the newly added anchor; replacing a conflicting pin is offered only then.
    private static func validate(_ track: TimingTrack, assetID: MediaAssetID?, changedAnchor: AnchorID?) throws -> TimingEditOutcome {
        do {
            let map = try TimingMap(track: track, assetID: assetID)
            return TimingEditOutcome(track: track, report: map.report)
        } catch let conflict as AnchorConflict {
            let others = conflict.anchors.filter { $0 != changedAnchor }
            var options: [TimingResolution] = []
            if changedAnchor != nil { options += others.map { .replaceAnchor($0) } }
            options.append(.cancel)
            throw TimingEditConflict(message: conflict.message, options: options, anchors: conflict.anchors)
        }
    }

    /// Describes how the audio times of the given cursors change between two maps
    /// (for anchor deletion and tempo previews).
    public static func previewChange(from old: TimingMap, to new: TimingMap, cursors: [(String, TimelineCursor)]) -> [(label: String, before: Double, after: Double)] {
        cursors.compactMap { label, cursor in
            guard let before = try? old.audioTime(at: cursor), let after = try? new.audioTime(at: cursor) else { return nil }
            return (label, before, after)
        }
    }
}
