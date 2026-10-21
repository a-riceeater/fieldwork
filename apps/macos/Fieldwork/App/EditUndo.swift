import AppKit

/// Undo and Redo (Command-Z, Shift-Command-Z) act on the drill wherever focus
/// is: the field, lists, the timeline, popovers and sheets. Editable text keeps
/// its native text undo. The menu items use their own actions because NSWindow
/// answers the standard `undo:` with its text-only undo manager before the
/// editor sees it.
extension AppDelegate: NSMenuItemValidation {
    /// The editor of the frontmost show. It stays the main window while one of
    /// its sheets or popovers is key.
    private var activeEditor: EditorWindowController? {
        NSApp.mainWindow?.windowController as? EditorWindowController
    }

    /// The focused editable text, which handles Command-Z itself.
    private var editingText: NSResponder? {
        guard let responder = NSApp.keyWindow?.firstResponder else { return nil }
        if let text = responder as? NSTextView, text.isEditable { return text }
        if let field = responder as? NSTextField, field.isEditable { return field }
        return nil
    }

    @objc func undoEdit(_ sender: Any?) {
        if editingText != nil {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: sender)
        } else if let editor = activeEditor, editor.model.readOnlyReason == nil, editor.model.canUndo {
            editor.model.undo()
        } else {
            NSSound.beep()
        }
    }

    @objc func redoEdit(_ sender: Any?) {
        if editingText != nil {
            NSApp.sendAction(Selector(("redo:")), to: nil, from: sender)
        } else if let editor = activeEditor, editor.model.readOnlyReason == nil, editor.model.canRedo {
            editor.model.redo()
        } else {
            NSSound.beep()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let redo: Bool
        switch menuItem.action {
        case #selector(undoEdit(_:)): redo = false
        case #selector(redoEdit(_:)): redo = true
        default: return true
        }
        if let text = editingText {
            let manager = text.undoManager
            menuItem.title = (redo ? manager?.redoMenuItemTitle : manager?.undoMenuItemTitle) ?? (redo ? "Redo" : "Undo")
            return (redo ? manager?.canRedo : manager?.canUndo) ?? false
        }
        guard let model = activeEditor?.model else {
            menuItem.title = redo ? "Redo" : "Undo"
            return false
        }
        let name = redo ? model.redoName : model.undoName
        menuItem.title = name.map { "\(redo ? "Redo" : "Undo") \($0)" } ?? (redo ? "Redo" : "Undo")
        return model.readOnlyReason == nil && (redo ? model.canRedo : model.canUndo)
    }
}
