import AppKit
import SwiftUI

/// Set the initial native dividers without replacing SwiftUI's split views or
/// their preference tree. Subsequent divider drags and window resizes are untouched.
struct EditorSplitDefaults: NSViewRepresentable {
    func makeNSView(context: Context) -> InitialEditorDividers { InitialEditorDividers() }
    func updateNSView(_ view: InitialEditorDividers, context: Context) {}
}

final class InitialEditorDividers: NSView {
    private var setColumns = false
    private var setRows = false
    private var scheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleDefaults()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleDefaults()
    }

    private func scheduleDefaults() {
        guard window != nil, !scheduled, !setColumns || !setRows else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.applyDefaults()
        }
    }

    private func applyDefaults() {
        window?.contentView?.layoutSubtreeIfNeeded()
        var ancestor = superview
        while let view = ancestor {
            if let split = view as? NSSplitView {
                if split.isVertical, split.subviews.count == 3, split.bounds.width > 900, !setColumns {
                    setColumns = true
                    split.setPosition(Tokens.Layout.navigator, ofDividerAt: 0)
                    split.setPosition(split.bounds.width - Tokens.Layout.inspector - split.dividerThickness, ofDividerAt: 1)
                } else if !split.isVertical, split.subviews.count == 2, split.bounds.height > 500, !setRows {
                    setRows = true
                    split.setPosition(split.bounds.height - Tokens.Layout.timeline - split.dividerThickness, ofDividerAt: 0)
                }
            }
            ancestor = view.superview
        }
    }
}
