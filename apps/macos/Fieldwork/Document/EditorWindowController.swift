import AppKit
import SwiftUI

/// Hosts the SwiftUI editor in an NSWindow. The SwiftUI toolbar is bridged
/// into the window toolbar (system Liquid Glass on macOS 26). Menu commands
/// arrive here through the responder chain.
final class EditorWindowController: NSWindowController, NSMenuItemValidation {
    let model: EditorModel

    @MainActor
    init(document: FieldworkDocument, model: EditorModel) {
        self.model = model
        let hosting = NSHostingController(rootView: EditorView(model: model))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.contentMinSize = NSSize(width: 1024, height: 720)
        window.backgroundColor = Tokens.window
        super.init(window: window)
        shouldCascadeWindows = true
        window.setFrameAutosaveName("FieldworkEditorWindow")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Edit

    @MainActor @objc override func selectAll(_ sender: Any?) { model.selectAll() }
    @MainActor @objc func deselectAll(_ sender: Any?) { model.selection = [] }

    // MARK: Set

    @MainActor @objc func addSet16(_ sender: Any?) { model.addSet(counts: 16) }
    @MainActor @objc func addSet8(_ sender: Any?) { model.addSet(counts: 8) }
    @MainActor @objc func deleteSet(_ sender: Any?) { model.deleteCurrentSet() }
    @MainActor @objc func splitMoveAtPlayhead(_ sender: Any?) { model.splitMoveAtPlayhead() }
    @MainActor @objc func previousSet(_ sender: Any?) { model.stepSet(-1) }
    @MainActor @objc func nextSet(_ sender: Any?) { model.stepSet(1) }
    @MainActor @objc func addSection(_ sender: Any?) { model.showAddSection = true }
    @MainActor @objc func projectSettings(_ sender: Any?) { model.showProjectSettings = true }
    @MainActor @objc func placeUnplaced(_ sender: Any?) { model.placeUnplaced() }
    @MainActor @objc func arrangeLine(_ sender: Any?) { model.placeSelection(in: .line) }
    @MainActor @objc func arrangeArc(_ sender: Any?) { model.placeSelection(in: .arc) }
    @MainActor @objc func arrangeBlock(_ sender: Any?) { model.placeSelection(in: .block) }
    @MainActor @objc func arrangeCircle(_ sender: Any?) { model.placeSelection(in: .circle) }

    // MARK: Tools and view

    @MainActor @objc func toolSelect(_ sender: Any?) { model.tool = .select }
    @MainActor @objc func toolLine(_ sender: Any?) { model.tool = .line }
    @MainActor @objc func toolArc(_ sender: Any?) { model.tool = .arc }
    @MainActor @objc func toggleSnap(_ sender: Any?) { model.snapEnabled.toggle() }
    @MainActor @objc func fitField(_ sender: Any?) { model.requestCanvas(.fitField) }
    @MainActor @objc func fitSelection(_ sender: Any?) { model.requestCanvas(.fitSelection) }
    @MainActor @objc func zoomInField(_ sender: Any?) { model.requestCanvas(.zoomIn) }
    @MainActor @objc func zoomOutField(_ sender: Any?) { model.requestCanvas(.zoomOut) }
    @MainActor @objc func toggleCirclesOnly(_ sender: Any?) { model.circlesOnly.toggle() }
    @MainActor @objc func setFieldStyle(_ sender: Any?) {
        if let raw = (sender as? NSMenuItem)?.representedObject as? String, let style = FieldStyle(rawValue: raw) { model.fieldStyle = style }
    }
    @MainActor @objc func addNote(_ sender: Any?) { model.addNote() }

    // MARK: Playback, audio, export, help

    @MainActor @objc func togglePlayback(_ sender: Any?) { model.togglePlay() }
    @MainActor @objc func toggleWholeCounts(_ sender: Any?) { model.wholeCountsOnly.toggle() }
    @MainActor @objc func goToStart(_ sender: Any?) { model.selectSet(model.setsInMovement[0].id) }
    @MainActor @objc func importAudio(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .mp3]
        panel.message = "Choose a WAV or MP3 file. It will be copied into the show."
        if panel.runModal() == .OK, let url = panel.url { model.importAudio(from: url) }
    }
    @MainActor @objc func exportCoordinates(_ sender: Any?) { model.showExport = true }
    @MainActor @objc func gettingStarted(_ sender: Any?) { model.restartTour() }

    @MainActor
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleSnap(_:)):
            menuItem.state = model.snapEnabled ? .on : .off
            return true
        case #selector(togglePlayback(_:)):
            menuItem.title = model.isPlaying ? "Pause" : "Play"
            return true
        case #selector(addNote(_:)):
            return model.isEditable
        case #selector(toggleCirclesOnly(_:)):
            menuItem.state = model.circlesOnly ? .on : .off
            return true
        case #selector(setFieldStyle(_:)):
            menuItem.state = menuItem.representedObject as? String == model.fieldStyle.rawValue ? .on : .off
            return true
        case #selector(toggleWholeCounts(_:)):
            menuItem.state = model.wholeCountsOnly ? .on : .off
            return true
        case #selector(toolSelect(_:)): menuItem.state = model.tool == .select ? .on : .off; return true
        case #selector(toolLine(_:)): menuItem.state = model.tool == .line ? .on : .off; return true
        case #selector(toolArc(_:)): menuItem.state = model.tool == .arc ? .on : .off; return true
        case #selector(deleteSet(_:)):
            return model.show.previousSet(before: model.currentSetID) != nil && model.isEditable
        case #selector(splitMoveAtPlayhead(_:)):
            menuItem.title = model.playheadSplit.map { "Split Move at Count \($0.count)" } ?? "Split Move at Playhead"
            return model.playheadSplit != nil && model.readOnlyReason == nil
        case #selector(placeUnplaced(_:)):
            return model.isEditable && model.unplacedCount > 0
        case #selector(arrangeLine(_:)), #selector(arrangeArc(_:)), #selector(arrangeBlock(_:)), #selector(arrangeCircle(_:)):
            return model.isEditable && !model.selection.isEmpty
        case #selector(addSet16(_:)), #selector(addSet8(_:)), #selector(addSection(_:)), #selector(importAudio(_:)):
            return model.readOnlyReason == nil
        default:
            return true
        }
    }
}
