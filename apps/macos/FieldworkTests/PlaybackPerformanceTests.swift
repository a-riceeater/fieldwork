import XCTest
import SwiftUI
import Combine
import DrillCore
import DrillDocument
@testable import Fieldwork

final class PlaybackPerformanceTests: XCTestCase {
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
