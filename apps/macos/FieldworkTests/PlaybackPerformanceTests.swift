import XCTest
import SwiftUI
import Combine
import DrillCore
import DrillDocument
@testable import Fieldwork

final class PlaybackPerformanceTests: XCTestCase {
    @MainActor
    func testFrameUpdatesReachNativeSurfacesWithoutInvalidatingDocumentUI() throws {
        let show = try SampleShow.makeLarge(performers: 350, sets: 150)
        let model = EditorModel(session: try DocumentSession(show: show), assets: [:])
        let canvas = FieldCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let timeline = TimelineCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 180))
        let fieldCoordinator = FieldCanvas.Coordinator(model: model)
        let timelineCoordinator = TimelineLanes.Coordinator(model: model)
        fieldCoordinator.connect(canvas)
        timelineCoordinator.connect(timeline)
        timeline.state = model.timelineState()
        model.play()
        defer { model.pause() }
        var invalidations = 0
        let observer = model.objectWillChange.sink { invalidations += 1 }
        defer { observer.cancel() }
        for time in [0.0, 1.25, 4.0, 100.5, model.timelineDuration] {
            model.playheadSeconds = time
            let expected = try XCTUnwrap(model.evaluator).evaluate(audioTime: time)
            let state = try XCTUnwrap(canvas.state)
            XCTAssertEqual(state.dots.count, 350)
            XCTAssertTrue(state.paths.isEmpty)
            XCTAssertTrue(state.warningPaths.isEmpty)
            XCTAssertEqual(state.dots.first?.id, expected.performers.first?.id)
            XCTAssertEqual(try XCTUnwrap(state.dots.first?.point.x), expected.performers[0].x, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(state.dots.first?.point.y), expected.performers[0].y, accuracy: 1e-9)
            XCTAssertEqual(timeline.state?.playhead, time)
        }
        XCTAssertEqual(invalidations, 0, "Playback must not invalidate the set list, inspector or toolbar")
        model.pause()
        XCTAssertEqual(model.playbackPosition.readoutSeconds, model.playheadSeconds)
        XCTAssertGreaterThan(invalidations, 0, "Pausing must restore the editing UI")
    }

    @MainActor
    func testCachedFieldUpdatesForStyleZoomResizeAndFieldEdits() throws {
        let model = EditorModel(session: try DocumentSession(show: SampleShow.make()), assets: [:])
        let canvas = FieldCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        canvas.state = model.canvasState()
        func render() throws -> Data {
            let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let original = try render()
        XCTAssertEqual(try render(), original)
        for style in FieldStyle.allCases where style != model.fieldStyle {
            var state = try XCTUnwrap(canvas.state)
            state.fieldStyle = style
            canvas.state = state
            XCTAssertNotEqual(try render(), original)
        }
        canvas.state = model.canvasState()
        canvas.fit(.zoomIn)
        XCTAssertNotEqual(try render(), original)
        canvas.fit(.fitField)
        XCTAssertEqual(try render(), original)
        canvas.setFrameSize(NSSize(width: 900, height: 650))
        XCTAssertNotEqual(try render(), original)
        canvas.setFrameSize(NSSize(width: 800, height: 600))
        XCTAssertEqual(try render(), original)
        var state = try XCTUnwrap(canvas.state)
        state.field = Field.make(.indoorFloor)
        canvas.state = state
        XCTAssertNotEqual(try render(), original)
    }

    @MainActor
    func testTimelinePlayheadCompositesWithoutRedrawingWaveform() throws {
        let model = EditorModel(session: try DocumentSession(show: SampleShow.make()), assets: [:])
        let timeline = TimelineCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 180))
        let window = NSWindow(contentRect: timeline.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = timeline
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        timeline.state = model.timelineState()
        timeline.displayIfNeeded()
        timeline.needsDisplay = false
        timeline.state?.playhead = 0.5
        XCTAssertFalse(timeline.needsDisplay, "A clock tick must not redraw the waveform and marker labels")
        let playhead = try XCTUnwrap(timeline.layer?.sublayers?.first { $0.name == "timeline.playhead" })
        XCTAssertEqual(playhead.frame.midX, timeline.x(0.5), accuracy: 1e-6)
        timeline.zoom(by: 2, at: 100)
        XCTAssertEqual(playhead.frame.midX, timeline.x(0.5), accuracy: 1e-6)
        timeline.setFrameSize(NSSize(width: 900, height: 220))
        XCTAssertEqual(playhead.frame.height, 220)
        timeline.needsDisplay = false
        timeline.state?.playhead = 1000
        XCTAssertEqual(timeline.time(timeline.bounds.width), model.timelineDuration + 1, accuracy: 1e-6)
        XCTAssertEqual(playhead.frame.midX, timeline.x(1000), accuracy: 1e-6)
    }

    /// Opt in with FIELDWORK_PROFILE_DOCUMENT=/path/to/show.fieldwork. Never writes the input.
    @MainActor
    func testDocumentPlaybackProfile() throws {
        guard let path = ProcessInfo.processInfo.environment["FIELDWORK_PROFILE_DOCUMENT"] else {
            throw XCTSkip("Set FIELDWORK_PROFILE_DOCUMENT to profile a real show")
        }
        let document = try path == "synthetic"
            ? ShowDocument(show: SampleShow.makeLarge(performers: 350, sets: 150))
            : DocumentCodec.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        let suite = "FieldworkProfile.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(ProcessInfo.processInfo.environment["FIELDWORK_PROFILE_STYLE"] ?? "dark", forKey: "FieldworkFieldStyle")
        let includeAudio = ProcessInfo.processInfo.environment["FIELDWORK_PROFILE_AUDIO"] == "1"
        let model = EditorModel(session: try DocumentSession(show: document.show), assets: includeAudio ? document.assets : [:], preferences: preferences)
        model.alwaysShowLabels = ProcessInfo.processInfo.environment["FIELDWORK_PROFILE_LABELS"] == "1"
        if includeAudio {
            let deadline = Date(timeIntervalSinceNow: 30)
            while model.peaks == nil && Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            XCTAssertNotNil(model.peaks, model.audioStatus)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 960),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: EditorView(model: model))
        window.orderFront(nil)
        defer { model.pause(); window.orderOut(nil) }
        model.play()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        var frames: [Double] = []
        for frame in 0..<120 {
            let start = CFAbsoluteTimeGetCurrent()
            model.playheadSeconds = 10 + Double(frame) / 60
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0 / 60))
            window.displayIfNeeded()
            frames.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        // Check a later move as well as the beginning; audio and no-audio use the same clock path.
        model.seek(to: 45)
        var liveIntervals: [Double] = []
        var previous = CFAbsoluteTimeGetCurrent()
        let clock = model.playbackPosition.frames.sink { _ in
            let now = CFAbsoluteTimeGetCurrent()
            liveIntervals.append((now - previous) * 1000)
            previous = now
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 3))
        clock.cancel()
        liveIntervals.sort()
        XCTAssertGreaterThan(liveIntervals.count, 0, "The visible canvas must receive display-link callbacks")
        if !liveIntervals.isEmpty {
            print("LIVE CLOCK: \(liveIntervals.count) frames / 3 s (audio=\(includeAudio), style=\(model.fieldStyle.rawValue)); p50=\(liveIntervals[liveIntervals.count / 2]) ms p95=\(liveIntervals[Int(Double(liveIntervals.count - 1) * 0.95)]) ms")
        }
        frames.sort()
        print("PLAYBACK PROFILE: \(document.show.performers.count) performers, \(document.show.sets.count) sets; frame interval p50=\(frames[60]) ms p95=\(frames[114]) ms max=\(frames.last!) ms")
    }
}
