import XCTest
import SwiftUI
import DrillCore
@testable import Fieldwork

final class EditorLayoutTests: XCTestCase {
    func testPaneDefaultsAndNarrowWindowKeepSpaceForField() {
        let defaults = EditorPaneSizes()
        XCTAssertEqual(defaults.navigator, 220)
        XCTAssertEqual(defaults.inspector, 260)
        XCTAssertEqual(defaults.timeline, 180)
        let narrow = EditorPaneSizes(navigator: 320, inspector: 360, timeline: 420).fitted(to: CGSize(width: 1024, height: 650))
        XCTAssertGreaterThanOrEqual(1024 - narrow.navigator - narrow.inspector - 8, 420)
        XCTAssertGreaterThanOrEqual(650 - narrow.timeline - 4, 360)
    }

    @MainActor
    func testInitialWorkspaceGivesFieldRemainingSpace() throws {
        let model = EditorModel(session: try DocumentSession(show: SampleShow.make()), assets: [:])
        let window = UnconstrainedWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: EditorView(model: model))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let canvas = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? FieldCanvasView }.first)
        XCTAssertEqual(canvas.bounds.width, 1440 - 220 - 260 - 8, accuracy: 2)
        XCTAssertGreaterThan(canvas.bounds.height, 650)
        XCTAssertEqual(canvas.transform, CanvasTransform.fit(model.show.field.bounds, in: canvas.bounds))
        model.snapEnabled.toggle()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(canvas.bounds.width, 1440 - 220 - 260 - 8, accuracy: 2)
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
    func testZoomOutStopsAtFullFieldAndFollowsViewportSize() throws {
        let model = EditorModel(session: try DocumentSession(show: SampleShow.make()), assets: [:])
        let canvas = FieldCanvasView(frame: NSRect(x: 0, y: 0, width: 980, height: 680))
        canvas.state = model.canvasState()
        let fitted = CanvasTransform.fit(model.show.field.bounds, in: canvas.bounds)
        for _ in 0..<4 { canvas.fit(.zoomIn) }
        XCTAssertGreaterThan(canvas.transform.scale, fitted.scale)
        for _ in 0..<20 { canvas.fit(.zoomOut) }
        XCTAssertEqual(canvas.transform, fitted)
        canvas.setFrameSize(NSSize(width: 1200, height: 800))
        XCTAssertEqual(canvas.transform, CanvasTransform.fit(model.show.field.bounds, in: canvas.bounds))

        // Enlarging the viewport must also respect its new zoom-out limit when
        // the prior view was manually zoomed, rather than following field fit.
        canvas.fit(.zoomIn)
        canvas.setFrameSize(NSSize(width: 1800, height: 1200))
        XCTAssertEqual(canvas.transform, CanvasTransform.fit(model.show.field.bounds, in: canvas.bounds))
    }

    @MainActor
    func testZoomedCanvasCannotPaintOutsideItsViewport() throws {
        let model = EditorModel(session: try DocumentSession(show: SampleShow.make()), assets: [:])
        let canvas = FieldCanvasView(frame: NSRect(x: 0, y: 0, width: 200, height: 160))
        canvas.state = model.canvasState()
        canvas.fit(.zoomIn)
        var state = try XCTUnwrap(canvas.state)
        var dot = try XCTUnwrap(state.dots.first)
        dot.point = canvas.transform.toWorld(CGPoint(x: -3, y: 80), in: canvas.bounds)
        dot.selected = true
        state.dots = [dot]
        state.alwaysShowLabels = true
        canvas.state = state
        XCTAssertTrue(canvas.clipsToBounds)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 280, pixelsHigh: 240,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        let ctx = graphics.cgContext
        ctx.setFillColor(NSColor.magenta.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 280, height: 240))
        ctx.translateBy(x: 40, y: 40)
        let originalClip = ctx.boundingBoxOfClipPath
        // Draw directly into a larger surface to catch pixels that would spill onto nearby UI.
        canvas.draw(canvas.bounds)
        XCTAssertEqual(ctx.boundingBoxOfClipPath, originalClip)
        let outside = try XCTUnwrap(bitmap.colorAt(x: 36, y: 120)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(outside.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(outside.greenComponent, 0, accuracy: 0.01)
        XCTAssertEqual(outside.blueComponent, 1, accuracy: 0.01)
        let inside = try XCTUnwrap(bitmap.colorAt(x: 140, y: 120)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(inside.redComponent + inside.blueComponent, 1.9)
    }

    @MainActor
    func testTightPerformerIntervalsRemainVisiblySeparateAtMidrangeZooms() throws {
        let model = EditorModel(session: try DocumentSession(show: SampleShow.make()), assets: [:])
        let canvas = FieldCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var state = model.canvasState()
        state.fieldStyle = .dark
        state.forms = []
        state.paths = []
        state.notes = []
        var dot = try XCTUnwrap(state.dots.first)
        dot.symbol = .circle
        dot.selected = false
        dot.label = ""
        state.dots = []
        canvas.state = state

        func render() throws -> NSBitmapImageRep {
            let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            return bitmap
        }
        for minimumScale: CGFloat in [15, 25, 40] {
            while canvas.transform.scale < minimumScale { canvas.fit(.zoomIn) }
            // Half-meter intervals in lines, diagonals and a curved formation.
            for points in [
                [Point2(-0.25, 0), Point2(0.25, 0)],
                [Point2(-0.15, -0.2), Point2(0.15, 0.2)],
                (0..<12).map { Point2(cos(Double($0) * .pi / 6), sin(Double($0) * .pi / 6)) }
            ] {
                state.dots = []
                canvas.state = state
                let empty = try render()
                state.dots = points.map { point in
                    var performer = dot
                    performer.id = PerformerID()
                    performer.point = point
                    return performer
                }
                canvas.state = state
                let placed = try render()
                // Empty labels isolate the markers from text placement.
                let a = points[0], b = points[1]
                let midpoint = canvas.transform.toView(Point2((a.x + b.x) / 2, (a.y + b.y) / 2), in: canvas.bounds)
                let x = Int(midpoint.x * CGFloat(placed.pixelsWide) / canvas.bounds.width)
                let y = placed.pixelsHigh - 1 - Int(midpoint.y * CGFloat(placed.pixelsHigh) / canvas.bounds.height)
                let gap = try XCTUnwrap(placed.colorAt(x: x, y: y))
                XCTAssertEqual(gap, empty.colorAt(x: x, y: y), "An interval must show field between dot centers at scale \(canvas.transform.scale)")
            }
        }
    }

    @MainActor
    func testFrontLabelInkStaysOnePointFromDotAtEveryZoom() throws {
        for scale: CGFloat in [1, 2] {
            for label in ["T1", "bc12", "g9"] {
                let text = NSAttributedString(string: label, attributes: [
                    .font: NSFont.systemFont(ofSize: 8, weight: .medium),
                    .foregroundColor: NSColor.black, .strokeColor: NSColor.white, .strokeWidth: -3
                ])
                let cached = try XCTUnwrap(FieldCanvasView.rasterizeLabel(text, scale: scale))
                XCTAssertLessThan(cached.inkSize.height, cached.size.height)
                let bitmap = NSBitmapImageRep(cgImage: cached.inkImage)
                for row in [0, bitmap.pixelsHigh - 1] {
                    XCTAssertTrue((0..<bitmap.pixelsWide).contains {
                        (bitmap.colorAt(x: $0, y: row)?.alphaComponent ?? 0) > 0
                    }, "Visible ink must reach both vertical edges of the cropped label")
                }
                for radius: CGFloat in [3.5, 5, 9] {
                    let origin = PerformerLabelPlacement.front.origin(at: .zero, radius: radius, size: cached.inkSize)
                    XCTAssertEqual(-radius - (origin.y + cached.inkSize.height), 1, accuracy: 0.001)
                }
            }
        }
    }

    func testFrontLabelsCenterDifferentWidthsTowardAudience() {
        let point = CGPoint(x: 100, y: 200)
        for width: CGFloat in [10, 25] {
            let size = CGSize(width: width, height: 12)
            let origin = PerformerLabelPlacement.front.origin(at: point, radius: 5, size: size)
            XCTAssertEqual(origin.x + width / 2, point.x)
            XCTAssertEqual(origin.y + size.height, point.y - 6)
            XCTAssertEqual(PerformerLabelPlacement.offset.origin(at: point, radius: 5, size: size),
                           CGPoint(x: 106, y: 200))
        }
    }

    @MainActor
    func testAlwaysVisibleLabelsPersistAndRenderWhenZoomedOut() throws {
        let suite = "FieldworkLabelTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = try DocumentSession(show: SampleShow.make())
        let model = EditorModel(session: session, assets: [:], preferences: preferences)
        XCTAssertFalse(model.alwaysShowLabels)
        XCTAssertEqual(model.labelPlacement, .front)
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
        let front = try render()
        model.labelPlacement = .offset
        canvas.state = model.canvasState()
        XCTAssertNotEqual(try render(), front)
        model.labelPlacement = .front
        canvas.state = model.canvasState()
        XCTAssertEqual(try render(), front)
        model.labelPlacement = .offset
        let reopened = EditorModel(session: session, assets: [:], preferences: preferences)
        XCTAssertTrue(reopened.alwaysShowLabels)
        XCTAssertEqual(reopened.labelPlacement, .offset)
        XCTAssertFalse(session.isDirty)
    }
}

/// Keeps its requested frame when shown. AppKit otherwise shrinks titled
/// windows to the screen, and CI runners have a 1024x768 display.
private final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
