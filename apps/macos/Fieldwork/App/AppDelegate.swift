import AppKit
import SwiftUI
import DrillCore
import DrillDocument

/// AppKit lifecycle so NSDocument owns document windows and saving. SwiftUI
/// provides the content of every window.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var retained: AppDelegate?
    private var welcomeWindow: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retained = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        offerRecovery()
        if NSDocumentController.shared.documents.isEmpty { showWelcome(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome(nil) }
        return true
    }

    // MARK: Welcome and new shows

    @objc func showWelcome(_ sender: Any?) {
        if let welcomeWindow {
            welcomeWindow.makeKeyAndOrderFront(nil)
            return
        }
        let view = WelcomeView(
            create: { [weak self] request in self?.createShow(request) },
            open: { NSDocumentController.shared.openDocument(nil) },
            sample: { [weak self] in self?.openSample(nil) },
            openRecent: { url in
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error { NSApp.presentError(error) }
                }
            })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to Fieldwork"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        welcomeWindow = window
    }

    private func closeWelcome() {
        welcomeWindow?.close()
        welcomeWindow = nil
    }

    @objc func newShow(_ sender: Any?) {
        showWelcome(nil)
        NotificationCenter.default.post(name: WelcomeView.beginNewShow, object: nil)
    }

    private func createShow(_ request: NewShowRequest) {
        do {
            let show = try request.build()
            open(show: show, startTour: true, audio: request.audioURL)
            closeWelcome()
        } catch {
            NSApp.presentError(NSError(domain: "org.fieldwork", code: 10, userInfo: [NSLocalizedDescriptionKey: "The show could not be created.",
                                                                                    NSLocalizedRecoverySuggestionErrorKey: "\(error)"]))
        }
    }

    /// "Try a 90-second Sample": an untitled, editable copy; existing documents are untouched.
    @objc func openSample(_ sender: Any?) {
        do {
            open(show: try SampleShow.make(), startTour: true, audio: nil)
            closeWelcome()
        } catch {
            NSApp.presentError(error)
        }
    }

    private func open(show: Show, assets: [String: Data] = [:], startTour: Bool, audio: URL?, recovered: String? = nil) {
        let document = FieldworkDocument()
        document.pendingShow = show
        document.pendingAssets = assets
        document.startTourOnOpen = startTour
        document.audioToImport = audio
        document.recoveredMessage = recovered
        document.fileType = FieldworkDocument.typeIdentifier
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
    }

    @objc func gettingStarted(_ sender: Any?) {
        if let controller = NSApp.keyWindow?.windowController as? EditorWindowController {
            controller.gettingStarted(sender)
        } else {
            openSample(sender)
        }
    }

    // MARK: Crash recovery

    private func offerRecovery() {
        let openIDs = Set(NSDocumentController.shared.documents.compactMap { ($0 as? FieldworkDocument)?.recoveryID })
        for dir in RecoveryStore.leftovers(excluding: openIDs) {
            let recovery: RecoveryJournal.Recovery?
            do { recovery = try RecoveryJournal.recover(from: dir) } catch {
                let alert = NSAlert()
                alert.messageText = "A recovery journal could not be read."
                alert.informativeText = "\(error)\n\nIt has been kept at \(dir.path)."
                alert.runModal()
                continue
            }
            guard let recovery, !recovery.events.isEmpty else {
                try? FileManager.default.removeItem(at: dir)
                continue
            }
            let origin = RecoveryStore.origin(in: dir)
            let title = origin["title"] ?? recovery.base.show.title
            let alert = NSAlert()
            alert.messageText = "Recover unsaved changes to “\(title)”?"
            var info = "Fieldwork closed unexpectedly with \(recovery.events.count) unsaved change\(recovery.events.count == 1 ? "" : "s")."
            if let file = origin["file"], !file.isEmpty { info += " The original file at \(file) has not been modified." }
            if recovery.ignoredPartialLine { info += " The last, incomplete change could not be recovered." }
            alert.informativeText = info
            alert.addButton(withTitle: "Recover")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Decide Later")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                do {
                    let (session, document) = try RecoveryJournal.restore(recovery)
                    open(show: session.show, assets: document.assets, startTour: false, audio: nil,
                         recovered: "Recovered \(recovery.events.count) unsaved change\(recovery.events.count == 1 ? "" : "s"). Save to keep them.")
                    try? FileManager.default.removeItem(at: dir)
                } catch {
                    NSApp.presentError(NSError(domain: "org.fieldwork", code: 11, userInfo: [NSLocalizedDescriptionKey: "Recovery failed.",
                                                                                            NSLocalizedRecoverySuggestionErrorKey: "\(error)"]))
                }
            case .alertSecondButtonReturn:
                try? FileManager.default.removeItem(at: dir)
            default:
                break
            }
        }
    }
}
