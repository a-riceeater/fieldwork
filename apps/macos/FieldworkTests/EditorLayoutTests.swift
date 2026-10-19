import XCTest
import SwiftUI
import DrillCore
@testable import Fieldwork

final class EditorLayoutTests: XCTestCase {
    func testPaneDefaultsAndNarrowWindowKeepSpaceForField() {
        let defaults = EditorPaneSizes()
        XCTAssertEqual(defaults.navigator, 190)
        XCTAssertEqual(defaults.inspector, 260)
        XCTAssertEqual(defaults.timeline, 180)
        let narrow = EditorPaneSizes(navigator: 320, inspector: 360, timeline: 420).fitted(to: CGSize(width: 1024, height: 650))
        XCTAssertGreaterThanOrEqual(1024 - narrow.navigator - narrow.inspector - 8, 420)
        XCTAssertGreaterThanOrEqual(650 - narrow.timeline - 4, 360)
    }

    @MainActor
    func testInitialWorkspaceGivesFieldRemainingSpace() throws {
        let model = EditorModel(session: try DocumentSession(show: SampleShow.make()), assets: [:])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: EditorView(model: model))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let canvas = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? FieldCanvasView }.first)
        XCTAssertEqual(canvas.bounds.width, 1440 - 190 - 260 - 8, accuracy: 2)
        XCTAssertGreaterThan(canvas.bounds.height, 650)
        XCTAssertEqual(canvas.transform, CanvasTransform.fit(model.show.field.bounds, in: canvas.bounds))
        model.snapEnabled.toggle()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(canvas.bounds.width, 1440 - 190 - 260 - 8, accuracy: 2)
    }

    @MainActor
    func testFieldFitFollowsLayoutButPreservesManualZoom() throws {
        let model = EditorModel(session: try DocumentSession(show: SampleShow.make()), assets: [:])
        let canvas = FieldCanvasView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
        canvas.state = model.canvasState()
        canvas.setFrameSize(NSSize(width: 980, height: 680))
        XCTAssertEqual(canvas.transform, CanvasTransform.fit(model.show.field.bounds, in: canvas.bounds))
        canvas.fit(.zoomIn)
        let zoomed = canvas.transform
        canvas.setFrameSize(NSSize(width: 900, height: 640))
        XCTAssertEqual(canvas.transform, zoomed)
        canvas.fit(.fitField)
        canvas.setFrameSize(NSSize(width: 1000, height: 700))
        XCTAssertEqual(canvas.transform, CanvasTransform.fit(model.show.field.bounds, in: canvas.bounds))
    }

    @MainActor
    func testAlwaysVisibleLabelsPersistAndRenderWhenZoomedOut() throws {
        let suite = "FieldworkLabelTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = try DocumentSession(show: SampleShow.make())
        let model = EditorModel(session: session, assets: [:], preferences: preferences)
        XCTAssertFalse(model.alwaysShowLabels)
        let canvas = FieldCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        canvas.state = model.canvasState()
        canvas.fit(.zoomOut)
        func render() throws -> Data {
            let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let hidden = try render()
        model.alwaysShowLabels = true
        canvas.state = model.canvasState()
        XCTAssertTrue(try XCTUnwrap(canvas.state).alwaysShowLabels)
        XCTAssertNotEqual(try render(), hidden)
        let reopened = EditorModel(session: session, assets: [:], preferences: preferences)
        XCTAssertTrue(reopened.alwaysShowLabels)
        XCTAssertFalse(session.isDirty)
    }
}
