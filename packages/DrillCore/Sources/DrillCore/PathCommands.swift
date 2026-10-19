import Foundation
import DrillTiming

/// One row of a path's breakdown in the inspector.
public struct PathSegmentInfo: Hashable, Sendable {
    public var index: Int
    public var kind: String
    /// Counts into the move where the segment starts.
    public var startCount: Rational
    public var counts: Rational
    /// Meters traveled.
    public var length: Double
    /// Meters per count.
    public var pace: Double
    /// Steps per five yards at this pace (8 = 8-to-5); infinite for a hold.
    public var stepsPerFiveYards: Double
    public var start: Point2
    public var end: Point2
    public var sweep: Double?
}

extension Show {
    // MARK: Keeping paths valid

    /// Arrival pulses of every set in the movements asked for so far.
    struct PulseCache {
        var table: [MovementID: [SetID: Rational]] = [:]

        mutating func pulse(_ set: ArrivalSet, in show: Show) -> Rational? {
            if table[set.movementID] == nil {
                guard let pairs = try? show.setPulses(in: set.movementID) else { return nil }
                table[set.movementID] = Dictionary(uniqueKeysWithValues: pairs.map { ($0.set.id, $0.pulse) })
            }
            return table[set.movementID]?[set.id]
        }

        mutating func counts(into set: ArrivalSet, from previous: ArrivalSet, in show: Show) -> Rational? {
            guard let end = pulse(set, in: show), let start = pulse(previous, in: show) else { return nil }
            return end - start
        }
    }

    /// After an edit, brings every path into line with its move: a path whose move
    /// now starts from a different set, or whose performer is no longer placed at
    /// both ends, is dropped; a move whose counts changed scales its segments; a
    /// moved arrival moves the last leg's end (arcs keep their sweep). With `setID`,
    /// only the moves into and out of that set are checked.
    mutating func reconcilePaths(after old: Show, near setID: SetID? = nil) {
        guard transitions.contains(where: { !$0.paths.isEmpty }) else { return }
        var candidates: Set<SetID>?
        if let setID { candidates = Set([setID] + (nextSet(after: setID).map { [$0.id] } ?? [])) }
        var newPulses = PulseCache(), oldPulses = PulseCache()
        for i in transitions.indices where !transitions[i].paths.isEmpty {
            let target = transitions[i].toSetID
            if let candidates, !candidates.contains(target) { continue }
            guard let arrival = set(target), let from = previousSet(before: target), let oldArrival = old.set(target),
                  let oldFrom = old.previousSet(before: target), from.id == oldFrom.id, old.transition(into: target)?.id == transitions[i].id,
                  let counts = newPulses.counts(into: arrival, from: from, in: self), let oldCounts = oldPulses.counts(into: oldArrival, from: oldFrom, in: old),
                  counts > .zero, oldCounts > .zero else {
                transitions[i].paths = [:]
                continue
            }
            let start = formation(from.id), end = formation(target)
            var paths: [PerformerID: PerformerPath] = [:]
            for (id, path) in transitions[i].paths {
                guard let a = start[id].position, let b = end[id].position else { continue }
                var route = path
                if counts != oldCounts { route = route.scaled(by: counts / oldCounts) }
                route = route.movingEnd(to: b.point)
                paths[id] = PerformerPath.canonical(route.segments, from: a.point, to: b.point)
            }
            transitions[i].paths = paths
        }
    }

    /// Paths of the merged move when set `id` is deleted (A → S → B becomes A → B):
    /// each performer's route into S followed by their route out of it, so S's
    /// positions become waypoints. Returns the set the merged move arrives at.
    func mergedPaths(deleting id: SetID) throws -> (next: SetID?, paths: [PerformerID: PerformerPath]) {
        guard let s = set(id), let a = previousSet(before: id), let b = nextSet(after: id) else { return (nil, [:]) }
        let map = try timingMap(for: s.movementID)
        let pa = try map.pulse(at: a.cursor), ps = try map.pulse(at: s.cursor), pb = try map.pulse(at: b.cursor)
        let into = transition(into: id), out = transition(into: b.id)
        let fa = formation(a.id), fs = formation(id), fb = formation(b.id)
        var paths: [PerformerID: PerformerPath] = [:]
        for performer in performers {
            guard let p0 = fa[performer.id].position, let p1 = fs[performer.id].position, let p2 = fb[performer.id].position else { continue }
            let left = into?.paths[performer.id]?.segments ?? [.line(counts: ps - pa, to: p1.point)]
            let right = out?.paths[performer.id]?.segments ?? [.line(counts: pb - ps, to: p2.point)]
            paths[performer.id] = PerformerPath.canonical(left + right, from: p0.point, to: p2.point)
        }
        return (b.id, paths)
    }

    // MARK: Reading routes

    /// The move into a set: its transition, the set it starts from and its length in counts.
    public func move(into setID: SetID) throws -> (transition: Transition, from: ArrivalSet, counts: Rational) {
        guard let transition = transition(into: setID), let from = previousSet(before: setID) else {
            throw DrillError("The preset has no incoming move.")
        }
        return (transition, from, try moveCounts(into: setID))
    }

    /// A performer's route through the move into a set: their path, or one straight
    /// line when they have none. Nil unless they are placed at both ends.
    public func route(into setID: SetID, performer id: PerformerID) throws -> (start: Point2, end: Point2, segments: [PathSegment])? {
        let move = try move(into: setID)
        guard let a = formation(move.from.id)[id].position, let b = formation(setID)[id].position else { return nil }
        let segments = move.transition.paths[id]?.segments ?? [.line(counts: move.counts, to: b.point)]
        return (a.point, b.point, segments)
    }

    /// Per-segment counts, length and step size of a performer's route.
    public func pathSegmentInfo(into setID: SetID, performer id: PerformerID) throws -> [PathSegmentInfo] {
        guard let route = try route(into: setID, performer: id) else { return [] }
        return PerformerPath(route.segments).pieces(from: route.start).map { piece in
            var sweep: Double?
            if case .arc(_, _, let s) = piece.segment { sweep = s }
            return PathSegmentInfo(index: piece.index, kind: piece.segment.kindName, startCount: piece.startCount, counts: piece.counts,
                                   length: piece.length, pace: piece.pace,
                                   stepsPerFiveYards: piece.segment.isHold ? .infinity : DrillAnalyzer.stepsPerFiveYards(piece.pace),
                                   start: piece.start, end: piece.end, sweep: sweep)
        }
    }

    /// Indexes of the segments whose end is a waypoint: every line or arc except the last.
    public static func waypointSegments(_ segments: [PathSegment]) -> [Int] {
        guard let last = segments.lastIndex(where: { !$0.isHold }) else { return [] }
        return segments.indices.filter { $0 < last && !segments[$0].isHold }
    }

    // MARK: Editing paths

    /// Sets the given performers' routes in the move into a set; nil straightens.
    public func makeSetPaths(into setID: SetID, _ routes: [PerformerID: [PathSegment]?], name: String = "Edit Path") throws -> DrillCommand {
        let move = try move(into: setID)
        guard !routes.isEmpty else { throw DrillError("Nothing to change.") }
        return .batch(name, [.setPaths(move.transition.id, routes.mapValues { $0.map(PerformerPath.init) })])
    }

    /// Returns the selection to straight travel in the move into a set.
    public func makeStraighten(into setID: SetID, performers ids: [PerformerID]) throws -> DrillCommand {
        let move = try move(into: setID)
        let curved = ids.filter { move.transition.paths[$0] != nil }
        guard !curved.isEmpty else { throw DrillError("The selection already moves straight.") }
        return .batch(curved.count == 1 ? "Straighten Path" : "Straighten \(curved.count) Paths",
                      [.setPaths(move.transition.id, Dictionary(uniqueKeysWithValues: curved.map { ($0, nil) }))])
    }

    /// Sets how long the selection stands still at the start ("start late by n
    /// counts") and end ("arrive early by n counts") of the move into a set. Nil
    /// keeps the current hold. The legs in between keep their shape and relative
    /// timing and are stretched or squeezed into the counts that remain.
    public func makeHoldPhases(into setID: SetID, performers ids: [PerformerID], startHold: Rational?, endHold: Rational?) throws -> DrillCommand {
        let move = try move(into: setID)
        for hold in [startHold, endHold].compactMap({ $0 }) where hold < .zero {
            throw DrillError("Holds cannot be negative.")
        }
        var routes: [PerformerID: [PathSegment]?] = [:]
        for id in ids {
            guard let route = try route(into: setID, performer: id), route.segments.contains(where: { !$0.isHold }) else { continue }
            var middle = route.segments
            var lead = Rational.zero, trail = Rational.zero
            while let first = middle.first, first.isHold { lead += first.counts; middle.removeFirst() }
            while let last = middle.last, last.isHold { trail += last.counts; middle.removeLast() }
            let newLead = startHold ?? lead, newTrail = endHold ?? trail
            let remaining = move.counts - newLead - newTrail
            guard remaining > .zero else {
                throw DrillError("Holds of \(newLead) and \(newTrail) counts leave no time to move in a \(move.counts)-count move.")
            }
            let scaled = PerformerPath(middle).scaled(by: remaining / (move.counts - lead - trail)).segments
            routes[id] = (newLead > .zero ? [.hold(counts: newLead)] : []) + scaled + (newTrail > .zero ? [.hold(counts: newTrail)] : [])
        }
        guard !routes.isEmpty else { throw DrillError("Only performers who travel in this move can hold.") }
        let name = startHold != nil && endHold == nil ? "Start Late" : (endHold != nil && startHold == nil ? "Arrive Early" : "Set Holds")
        return .batch(name, [.setPaths(move.transition.id, routes.mapValues { $0.map(PerformerPath.init) })])
    }

    /// Splits the leg at `count` counts into the move and puts the new waypoint at `point`.
    public func makeInsertWaypoint(into setID: SetID, performer id: PerformerID, atCount count: Rational, at point: Point2) throws -> DrillCommand {
        let move = try move(into: setID)
        guard let route = try route(into: setID, performer: id) else { throw DrillError("Place the performer at both sets first.") }
        guard .zero < count, count < move.counts else { throw DrillError("Add the waypoint between count 0 and count \(move.counts).") }
        var (left, right, _) = PerformerPath(route.segments).split(at: count, from: route.start)
        guard let last = left.last, !last.isHold, let next = right.first, !next.isHold else {
            throw DrillError("Waypoints go on a moving leg, not during a hold.")
        }
        left[left.count - 1] = last.withEnd(point)
        return .batch("Add Waypoint", [.setPaths(move.transition.id, [id: PerformerPath(left + right)])])
    }

    /// Moves the waypoint at the end of segment `index` to `point`.
    public func makeMoveWaypoint(into setID: SetID, performer id: PerformerID, segment index: Int, to point: Point2) throws -> DrillCommand {
        let move = try move(into: setID)
        guard var route = try route(into: setID, performer: id), Show.waypointSegments(route.segments).contains(index) else {
            throw DrillError("That waypoint no longer exists.")
        }
        route.segments[index] = route.segments[index].withEnd(point)
        return .batch("Move Waypoint", [.setPaths(move.transition.id, [id: PerformerPath(route.segments)])])
    }

    /// Removes the waypoint at the end of segment `index`, joining its two legs into one straight leg.
    public func makeDeleteWaypoint(into setID: SetID, performer id: PerformerID, segment index: Int) throws -> DrillCommand {
        let move = try move(into: setID)
        guard var route = try route(into: setID, performer: id), Show.waypointSegments(route.segments).contains(index),
              let next = route.segments.indices.first(where: { $0 > index && !route.segments[$0].isHold }), let end = route.segments[next].end else {
            throw DrillError("That waypoint no longer exists.")
        }
        let counts = route.segments[index].counts + route.segments[next].counts
        route.segments[index] = .line(counts: counts, to: end)
        route.segments.remove(at: next)
        return .batch("Delete Waypoint", [.setPaths(move.transition.id, [id: PerformerPath(route.segments)])])
    }

    /// Bends leg `index` into a circular arc with the given signed sagitta
    /// (positive bulges to the left of the leg's direction). A sagitta within
    /// `snap` meters straightens the leg.
    public func makeCurveLeg(into setID: SetID, performer id: PerformerID, segment index: Int, sagitta: Double, snap: Double = 0) throws -> DrillCommand {
        let move = try move(into: setID)
        guard sagitta.isFinite else { throw DrillError("The curve must be a number.") }
        guard var route = try route(into: setID, performer: id), route.segments.indices.contains(index), !route.segments[index].isHold else {
            throw DrillError("Only a moving leg can be curved.")
        }
        let piece = PerformerPath(route.segments).pieces(from: route.start)[index]
        let chord = piece.start.distance(to: piece.end)
        guard chord > PerformerPath.minimumChord else { throw DrillError("A leg needs length before it can curve.") }
        if abs(sagitta) <= max(snap, PerformerPath.minimumSagitta) {
            route.segments[index] = .line(counts: piece.counts, to: piece.end)
        } else {
            route.segments[index] = .arc(counts: piece.counts, to: piece.end, sweep: PerformerPath.sweep(chord: chord, sagitta: sagitta))
        }
        return .batch(abs(sagitta) <= snap ? "Straighten Leg" : "Curve Leg", [.setPaths(move.transition.id, [id: PerformerPath(route.segments)])])
    }

    /// "Even pace along the whole path": redistributes each route's moving counts
    /// in proportion to leg length, keeping holds. Counts are rounded to 1/960.
    public func makeEvenPace(into setID: SetID, performers ids: [PerformerID]) throws -> DrillCommand {
        let move = try move(into: setID)
        var routes: [PerformerID: [PathSegment]?] = [:]
        for id in ids {
            guard move.transition.paths[id] != nil, let route = try route(into: setID, performer: id) else { continue }
            let pieces = PerformerPath(route.segments).pieces(from: route.start)
            let moving = pieces.filter { !$0.segment.isHold }
            let total = moving.reduce(0) { $0 + $1.length }
            guard moving.count > 1, total > 0 else { continue }
            let movingCounts = moving.reduce(Rational.zero) { $0 + $1.counts }
            var segments = route.segments
            var assigned = Rational.zero
            for (n, piece) in moving.enumerated() {
                let counts: Rational
                if n == moving.count - 1 {
                    counts = movingCounts - assigned
                } else {
                    let ticks = (movingCounts.doubleValue * piece.length / total * 960).rounded()
                    counts = Rational(max(1, Int64(ticks)), 960)
                }
                guard counts > .zero else { throw DrillError("The legs are too short to share the move's counts evenly.") }
                segments[piece.index] = piece.segment.withCounts(counts)
                assigned += counts
            }
            routes[id] = segments
        }
        guard !routes.isEmpty else { throw DrillError("Only paths with more than one leg can be evened out.") }
        return .batch("Even Pace", [.setPaths(move.transition.id, routes.mapValues { $0.map(PerformerPath.init) })])
    }
}
