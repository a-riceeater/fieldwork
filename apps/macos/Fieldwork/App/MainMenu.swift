import AppKit

/// Programmatic main menu. Actions travel the responder chain to the editor
/// window controller, NSDocument or the app delegate.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        main.addItem(submenu("", [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        let openRecent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        openRecent.submenu = recentMenu

        main.addItem(submenu("File", [
            item("New Show…", #selector(AppDelegate.newShow(_:)), "n"),
            item("Try the Sample Show", #selector(AppDelegate.openSample(_:))),
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            openRecent,
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save…", #selector(NSDocument.save(_:)), "s"),
            item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
            item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))),
            .separator(),
            item("Project Settings…", #selector(EditorWindowController.projectSettings(_:)), ",", [.command, .option]),
            .separator(),
            item("Import Audio…", #selector(EditorWindowController.importAudio(_:)), "i", [.command, .shift]),
            item("Export Coordinates…", #selector(EditorWindowController.exportCoordinates(_:)), "e", [.command, .shift]),
        ]))

        main.addItem(submenu("Edit", [
            item("Undo", #selector(EditorWindowController.undo(_:)), "z"),
            item("Redo", #selector(EditorWindowController.redo(_:)), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(EditorWindowController.selectAll(_:)), "a"),
            item("Deselect All", #selector(EditorWindowController.deselectAll(_:)), "a", [.command, .shift]),
        ]))

        main.addItem(submenu("Drill", [
            item("Select Tool", #selector(EditorWindowController.toolSelect(_:)), "1", [.command, .option]),
            item("Line Tool", #selector(EditorWindowController.toolLine(_:)), "2", [.command, .option]),
            item("Arc Tool", #selector(EditorWindowController.toolArc(_:)), "3", [.command, .option]),
            .separator(),
            item("Add Section…", #selector(EditorWindowController.addSection(_:)), "k", [.command, .shift]),
            item("Place All Unplaced Performers", #selector(EditorWindowController.placeUnplaced(_:))),
            submenu("Arrange Selection", [
                item("Line", #selector(EditorWindowController.arrangeLine(_:))),
                item("Arc", #selector(EditorWindowController.arrangeArc(_:))),
                item("Block", #selector(EditorWindowController.arrangeBlock(_:))),
                item("Circle", #selector(EditorWindowController.arrangeCircle(_:))),
            ]),
            item("Add 16-Count Set", #selector(EditorWindowController.addSet16(_:)), "\r", [.command]),
            item("Add 8-Count Set", #selector(EditorWindowController.addSet8(_:)), "\r", [.command, .option]),
            item("Delete Set", #selector(EditorWindowController.deleteSet(_:)), "\u{8}", [.command, .shift]),
            item("Split Move at Playhead", #selector(EditorWindowController.splitMoveAtPlayhead(_:))),
            item("Add Note", #selector(EditorWindowController.addNote(_:)), "n", [.command, .option]),
            .separator(),
            item("Previous Set", #selector(EditorWindowController.previousSet(_:)), "[", [.command]),
            item("Next Set", #selector(EditorWindowController.nextSet(_:)), "]", [.command]),
            .separator(),
            item("Snap to Grid", #selector(EditorWindowController.toggleSnap(_:)), "g", [.command]),
        ]))

        main.addItem(submenu("View", [
            item("Fit Field", #selector(EditorWindowController.fitField(_:)), "0"),
            item("Fit Selection", #selector(EditorWindowController.fitSelection(_:)), "0", [.command, .option]),
            item("Zoom In", #selector(EditorWindowController.zoomInField(_:)), "+"),
            item("Zoom Out", #selector(EditorWindowController.zoomOutField(_:)), "-"),
            .separator(),
            item("Draw Everyone as Circles", #selector(EditorWindowController.toggleCirclesOnly(_:)), "o", [.command, .option]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        main.addItem(submenu("Playback", [
            item("Play", #selector(EditorWindowController.togglePlayback(_:)), "p", [.command, .option]),
            item("Go to Start", #selector(EditorWindowController.goToStart(_:)), "\u{F729}", [.command]),
            .separator(),
            item("Whole Counts Only", #selector(EditorWindowController.toggleWholeCounts(_:))),
        ]))

        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Welcome", #selector(AppDelegate.showWelcome(_:)), "1", [.command, .shift]),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu

        let help = submenu("Help", [
            item("Getting Started", #selector(AppDelegate.gettingStarted(_:))),
        ])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }
}
