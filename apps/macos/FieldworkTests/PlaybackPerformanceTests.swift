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

    /// Opt in with FIELDWORK_PROFILE_DOCUMENT=/path/to/show.fieldwork. Never writes the input.
    @MainActor
    func testDocumentPlaybackProfile() throws {
        guard let path = ProcessInfo.processInfo.environment["FIELDWORK_PROFILE_DOCUMENT"] else {
            throw XCTSkip("Set FIELDWORK_PROFILE_DOCUMENT to profile a real show")
        }
        let document = try DocumentCodec.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        let model = EditorModel(session: try DocumentSession(show: document.show), assets: [:])
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
        frames.sort()
        print("PLAYBACK PROFILE: \(document.show.performers.count) performers, \(document.show.sets.count) sets; frame interval p50=\(frames[60]) ms p95=\(frames[114]) ms max=\(frames.last!) ms")
    }
}
