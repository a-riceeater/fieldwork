import Foundation
import DrillTiming
import DrillCore
import DrillDocument
import DrillMedia
import DrillExport

// fwtool: command-line access to the portable core for demos, fixtures,
// headless acceptance runs and profiling. It uses the same commands, codec
// and exporters as the native apps.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fwtool: \(message)\n".utf8))
    exit(1)
}

func log(_ message: String) { print(message) }

/// Original click-track audio: a short tick on every beat at `bpm`, after `leadIn` seconds.
func clickTrack(seconds: Double, sampleRate: Int, bpm: Double, leadIn: Double) -> Data {
    var samples = [Float](repeating: 0, count: Int(seconds * Double(sampleRate)))
    var beat = 0
    while true {
        let start = Int((leadIn + Double(beat) * 60 / bpm) * Double(sampleRate))
        guard start < samples.count else { break }
        let accent: Float = beat % 4 == 0 ? 0.8 : 0.45
        for k in 0..<min(400, samples.count - start) {
            samples[start + k] = Float(sin(Double(k) * (beat % 4 == 0 ? 0.55 : 0.4))) * accent * Float(1 - Double(k) / 400)
        }
        beat += 1
    }
    return WAVDecoder.encode16(samples, sampleRate: sampleRate)
}

func embedAudio(_ wav: Data, into document: inout ShowDocument, session: DocumentSession, name: String) throws -> MediaAssetInfo {
    let pcm = try WAVDecoder.decode(wav)
    let info = document.embed(wav, fileExtension: "wav", originalFilename: name, sampleRate: pcm.sampleRate, frameCount: pcm.frameCount, channelCount: pcm.channelCount)
    try session.perform(try session.show.makeImportAudio(info, movementID: session.show.movements[0].id))
    return info
}

func demo(_ path: String) throws {
    let session = try DocumentSession(show: try SampleShow.make())
    var document = ShowDocument(show: session.show)
    let rate = 11_025
    let info = try embedAudio(clickTrack(seconds: 32, sampleRate: rate, bpm: 120, leadIn: 1.5), into: &document, session: session, name: "demo-click.wav")
    let movement = session.show.movements[0].id
    let map = try session.timingMap(for: movement)
    try session.perform(try session.show.makeAlignHere(movementID: movement, cursor: try map.cursor(measureNumber: 1, beat: 1),
                                                       sampleFrame: Int64(1.5 * Double(rate))).command)
    document.show = session.show
    try DocumentFile.save(document, to: URL(fileURLWithPath: path))
    log("Wrote \(path): \(session.show.performers.count) performers, \(session.show.sets.count) sets, audio \(info.originalFilename) aligned at m1 b1 = 00:01.500")
}

/// Original synthetic show for the paths fixture: every segment kind, a mid-count
/// corner, holds at both ends and an arc of more than 180 degrees.
func pathsFixture(_ path: String) throws {
    let session = try DocumentSession(show: try Show.makeNew(title: "Fixture: Paths", measures: 4))
    try session.perform(try session.show.makeRoster([RosterSectionRequest(name: "Trumpet", prefix: "T", count: 4)]))
    let ids = session.show.performers.map(\.id)
    let preset = session.show.sets[0].id
    func place(_ set: SetID, _ points: [Point2]) throws {
        try session.perform(.setPlacements(set, Dictionary(uniqueKeysWithValues: zip(ids, points.map { Placement.placed(Position($0)) }))))
    }
    try place(preset, [Point2(-8, -4), Point2(0, 10), Point2(0, 0), Point2(10, 0)])
    try session.perform(try session.show.makeCreateSet(after: preset, counts: 8))
    let set2 = session.show.sets[1].id
    try place(set2, [Point2(-2, -4), Point2(10, 0), Point2(4.5, 3.5), Point2(0, 10)])
    try session.perform(try session.show.makeSetPaths(into: set2, [
        ids[0]: [.hold(counts: Rational(2)), .line(counts: Rational(6), to: Point2(-2, -4))],
        ids[1]: [.arc(counts: Rational(8), to: Point2(10, 0), sweep: 90)],
        ids[2]: [.line(counts: Rational(9, 2), to: Point2(4.5, 0)), .line(counts: Rational(7, 2), to: Point2(4.5, 3.5))],
        ids[3]: [.arc(counts: Rational(6), to: Point2(0, 10), sweep: 270), .hold(counts: Rational(2))],
    ]))
    try session.perform(try session.show.makeCreateSet(after: set2, counts: 6))
    let set3 = session.show.sets[2].id
    try place(set3, [Point2(-2, 2), Point2(10, 0), Point2(8, 3.5), Point2(0, 4)])
    try session.perform(try session.show.makeSetPaths(into: set3, [
        ids[0]: [.arc(counts: Rational(6), to: Point2(-2, 2), sweep: -180)],
        ids[2]: [.hold(counts: Rational(1, 2)), .line(counts: Rational(11, 2), to: Point2(8, 3.5))],
    ]))
    try DocumentFile.save(ShowDocument(show: session.show), to: URL(fileURLWithPath: path))
    log("Wrote \(path): \(session.show.pathCount) paths with \(session.show.pathSegmentCount) segments over \(session.show.sets.count) sets")
}

func acceptance(_ directory: String) throws {
    let dir = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let session = try DocumentSession(show: try Show.makeNew(title: "Acceptance", field: .make(.collegeFootball), measures: 16))
    try session.perform(try session.show.makeRoster([RosterSectionRequest(name: "Trumpet", prefix: "T", count: 12),
                                                     RosterSectionRequest(name: "Mellophone", prefix: "M", count: 8),
                                                     RosterSectionRequest(name: "Low Brass", prefix: "B", count: 12)]))
    log("1. Created \(session.show.performers.count) performers on \(session.show.field.name)")
    let ids = session.show.performers.map(\.id)
    let preset = session.show.sets[0].id
    let step = session.show.field.stepSize
    try session.perform(try session.show.makeForm(.line(start: Point2(-31 * step, 0), end: Point2(31 * step, 0)), members: Array(ids[0..<16]), at: preset))
    try session.perform(try session.show.makeForm(.arc(start: Point2(-15 * step, 8 * step), end: Point2(15 * step, 8 * step), bulge: 6 * step),
                                                  members: Array(ids[16...]), at: preset))
    log("2. Applied a line (16) and an arc (16) on the preset")
    try session.perform(try session.show.makeCreateSet(after: preset, counts: 16))
    let set2 = session.show.sets[1].id
    try session.perform(try session.show.makeTranslate(ids, at: set2, by: Point2(0, 8 * step)))
    log("3. Added a 16-count arrival and moved everyone 8 steps back")
    session.undo()
    session.redo()
    log("4. Undo/redo: \(session.redoName == nil ? "ok" : "unexpected redo state")")
    var document = ShowDocument(show: session.show)
    let rate = 22_050
    _ = try embedAudio(clickTrack(seconds: 30, sampleRate: rate, bpm: 120, leadIn: 2.0), into: &document, session: session, name: "click.wav")
    let movement = session.show.movements[0].id
    var map = try session.timingMap(for: movement)
    try session.perform(try session.show.makeAlignHere(movementID: movement, cursor: try map.cursor(measureNumber: 1, beat: 1), sampleFrame: Int64(2.0 * Double(rate))).command)
    map = try session.timingMap(for: movement)
    let second = try session.show.makeAlignHere(movementID: movement, cursor: try map.cursor(measureNumber: 5, beat: 1),
                                                sampleFrame: Int64((10.05 * Double(rate)).rounded()))
    try session.perform(second.command)
    let fit = second.report.intervals[0]
    log("5. Imported audio; pinned m1 b1 = 00:02.000 and m5 b1 = 00:10.050 (scale \(TimeFormat.decimal(fit.scale, places: 5)), mean \(TimeFormat.decimal(fit.meanTempo ?? 0, places: 3)) BPM)")
    map = try session.timingMap(for: movement)
    let evaluator = try SceneEvaluator(show: session.show, movementID: movement, map: map)
    let arrival = try map.audioTime(at: session.show.set(set2)!.cursor)
    for t in [arrival - 2, arrival - 0.5, arrival, arrival + 0.5] {
        let scene = evaluator.evaluate(audioTime: t)
        log("   t=\(TimeFormat.clock(t)) count \(TimeFormat.decimal(scene.pulse, places: 2)) set index \(scene.setIndex) T1 y=\(TimeFormat.decimal(scene.performers[0].y, places: 3)) m")
    }
    document.show = session.show
    let url = dir.appendingPathComponent("Acceptance.fieldwork")
    try DocumentFile.save(document, to: url)
    let reopened = try DocumentFile.open(url)
    guard reopened.show == session.show else { fail("reopened show differs") }
    let reopenedTime = try reopened.show.timingMap(for: movement).audioTime(at: reopened.show.set(set2)!.cursor)
    log("6. Saved and reopened \(url.lastPathComponent): identical model, set 2 arrival \(TimeFormat.clock(reopenedTime))")
    let pdf = try CoordinateSheet.render(reopened.show, movementID: movement)
    let pdfURL = dir.appendingPathComponent("Acceptance-coordinates.pdf")
    try pdf.write(to: pdfURL)
    log("7. Exported \(pdfURL.lastPathComponent) (\(pdf.count) bytes)")
}

func time<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let start = Date()
    let result = try body()
    return (result, Date().timeIntervalSince(start))
}

func profile(performers: Int, sets: Int) throws {
    log("Profile fixture: \(performers) performers × \(sets) sets")
    let (show, build) = try time { try SampleShow.makeLarge(performers: performers, sets: sets) }
    log("  build fixture        \(TimeFormat.decimal(build * 1000, places: 1)) ms")
    let (evaluator, prep) = try time { try SceneEvaluator(show: show, movementID: show.movements[0].id) }
    log("  evaluator setup      \(TimeFormat.decimal(prep * 1000, places: 1)) ms")
    let frames = 2000
    let total = evaluator.pulses.last ?? 1
    let (_, eval) = time {
        var checksum = 0.0
        for i in 0..<frames { checksum += evaluator.evaluate(pulse: total * Double(i) / Double(frames)).performers[0].x }
        return checksum
    }
    log("  evaluate frame       \(TimeFormat.decimal(eval / Double(frames) * 1_000_000, places: 1)) µs avg over \(frames) frames")
    let map = evaluator.map
    let (_, locate) = time {
        var s = 0.0
        for i in 0..<100_000 { s += map.locate(audioTime: Double(i) * 0.003).pulse }
        return s
    }
    log("  audio time → count   \(TimeFormat.decimal(locate / 100_000 * 1_000_000, places: 2)) µs avg")
    let (issues, analysis) = try time { try DrillAnalyzer.analyze(show, movementID: show.movements[0].id) }
    log("  full analysis        \(TimeFormat.decimal(analysis * 1000, places: 1)) ms (\(issues.count) issues)")
    let (data, encode) = try time { try DocumentCodec.encode(ShowDocument(show: show)) }
    log("  encode document      \(TimeFormat.decimal(encode * 1000, places: 1)) ms (\(data.count / 1024) KiB)")
    let (decoded, decode) = try time { try DocumentCodec.decode(data) }
    log("  decode document      \(TimeFormat.decimal(decode * 1000, places: 1)) ms (round trip \(decoded.show == show ? "identical" : "DIFFERENT"))")
    let session = try DocumentSession(show: show)
    let ids = Array(show.performers.map(\.id).prefix(50))
    let (_, drag) = try time {
        for _ in 0..<20 { try session.perform(try session.show.makeTranslate(ids, at: show.sets[75].id, by: Point2(0.1, 0))) }
    }
    log("  commit 50-dot drag   \(TimeFormat.decimal(drag / 20 * 1000, places: 2)) ms avg (validate + undo snapshot)")
}

/// Deterministic evaluation as JSON (positions rounded to micrometers) for cross-platform fixtures.
func evaluate(_ path: String, pulses: [Double]) throws {
    let show = try DocumentFile.open(URL(fileURLWithPath: path)).show
    let movement = show.movements[0].id
    let evaluator = try SceneEvaluator(show: show, movementID: movement)
    let map = evaluator.map
    var frames: [[String: Any]] = []
    for pulse in pulses {
        let scene = evaluator.evaluate(pulse: pulse)
        let positions = scene.performers.map { p -> [String: Any] in
            ["id": p.id.description, "x": (p.x * 1e6).rounded() / 1e6, "y": (p.y * 1e6).rounded() / 1e6, "state": "\(p.state)"]
        }
        frames.append(["pulse": pulse, "setIndex": scene.setIndex, "audioTime": ((try map.audioTime(atPulse: Rational(Int64((pulse * 1000).rounded()), 1000))) * 1e6).rounded() / 1e6,
                       "performers": positions])
    }
    let data = try JSONSerialization.data(withJSONObject: ["show": show.title, "frames": frames], options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func info(_ path: String) throws {
    let document = try DocumentFile.open(URL(fileURLWithPath: path))
    let show = document.show
    log("\(show.title): \(show.performers.count) performers in \(show.sections.count) sections, \(show.sets.count) sets, field \(show.field.name)")
    for movement in show.movements {
        let map = try show.timingMap(for: movement.id)
        log("  \(movement.name): \(movement.timing.measures.count) measures, \(movement.timing.anchors.count) anchors, audio \(movement.audioAssetID == nil ? "none" : "embedded")")
        for set in show.sets(in: movement.id) {
            let time = movement.audioAssetID == nil ? "" : " @ \(TimeFormat.clock(try map.audioTime(at: set.cursor)))"
            log("    Set \(set.label): count \(TimeFormat.decimal(try map.pulse(at: set.cursor).doubleValue, places: 2)) \(try map.musicalPosition(at: set.cursor).label)\(time)")
        }
    }
    let curvedMoves = show.transitions.filter { !$0.paths.isEmpty }.count
    log("  paths: \(show.pathCount) performer paths with \(show.pathSegmentCount) segments in \(curvedMoves) of \(show.transitions.count) moves; everyone else moves straight")
    if let reason = document.readOnlyReason { log("  read-only: \(reason)") }
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "demo":
        guard args.count == 2 else { fail("usage: fwtool demo <out.fieldwork>") }
        try demo(args[1])
    case "acceptance":
        guard args.count == 2 else { fail("usage: fwtool acceptance <output-directory>") }
        try acceptance(args[1])
    case "profile":
        let performers = args.count > 1 ? Int(args[1]) ?? 350 : 350
        let sets = args.count > 2 ? Int(args[2]) ?? 150 : 150
        try profile(performers: performers, sets: sets)
    case "pdf":
        guard args.count == 3 else { fail("usage: fwtool pdf <in.fieldwork> <out.pdf>") }
        let document = try DocumentFile.open(URL(fileURLWithPath: args[1]))
        try CoordinateSheet.render(document.show, movementID: document.show.movements[0].id).write(to: URL(fileURLWithPath: args[2]))
        log("Wrote \(args[2])")
    case "evaluate":
        guard args.count >= 3 else { fail("usage: fwtool evaluate <in.fieldwork> <count> [count...]") }
        try evaluate(args[1], pulses: args.dropFirst(2).compactMap(Double.init))
    case "paths-fixture":
        guard args.count == 2 else { fail("usage: fwtool paths-fixture <out.fieldwork>") }
        try pathsFixture(args[1])
    case "info":
        guard args.count == 2 else { fail("usage: fwtool info <in.fieldwork>") }
        try info(args[1])
    default:
        fail("usage: fwtool demo|acceptance|profile|pdf|info|evaluate|paths-fixture ...")
    }
} catch {
    fail("\(error)")
}
