import XCTest
import AppKit
@testable import Fieldwork

final class TimelineViewportTests: XCTestCase {
    @MainActor
    func testZoomOutStopsAtFullContentAndStaysThere() {
        let view = makeTimeline()
        view.zoom(by: 4, at: 400)
        let pointerTime = view.time(400)
        view.zoom(by: 2, at: 400)
        XCTAssertEqual(view.time(400), pointerTime, accuracy: 1e-6)
        for pointer: CGFloat in [0, 200, 800] {
            for _ in 0..<20 { view.zoom(by: 0.5, at: pointer) }
            XCTAssertEqual(view.time(0), -1, accuracy: 1e-6)
            XCTAssertEqual(view.time(800), 204, accuracy: 1e-6)
        }
        view.setFrameSize(NSSize(width: 1200, height: 180))
        XCTAssertEqual(view.time(0), -1, accuracy: 1e-6)
        XCTAssertEqual(view.time(1200), 204, accuracy: 1e-6)
    }

    @MainActor
    func testPanCannotLoseContentAtEitherEnd() throws {
        let view = makeTimeline()
        view.zoom(by: 4, at: 400)
        for (delta, expectedStart) in [(100_000.0, true), (-100_000.0, false)] {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                             wheelCount: 1, wheel1: Int32(delta), wheel2: 0, wheel3: 0))
            view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
            if expectedStart { XCTAssertEqual(view.time(0), -1, accuracy: 1e-6) }
            else { XCTAssertEqual(view.time(800), 204, accuracy: 1e-6) }
        }
        view.setFrameSize(NSSize(width: 4000, height: 180))
        XCTAssertEqual(view.time(0), -1, accuracy: 1e-6)
        XCTAssertEqual(view.time(4000), 204, accuracy: 1e-6)
    }

    @MainActor
    func testNegativeMusicalPreRollRemainsReachable() {
        let view = makeTimeline()
        view.state?.beats = [-12, -11, 0, 1]
        view.fitAll()
        view.zoom(by: 0.001, at: 800)
        XCTAssertEqual(view.time(0), -13, accuracy: 1e-6)
        XCTAssertEqual(view.time(800), 204, accuracy: 1e-6)
    }

    @MainActor
    private func makeTimeline() -> TimelineCanvasView {
        let view = TimelineCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 180))
        view.state = TimelineState(duration: 203, playhead: 0, measures: [], beats: [], sets: [],
                                   anchors: [], sampleRate: 48000, peaksFrameCount: 9_744_000)
        return view
    }
}
