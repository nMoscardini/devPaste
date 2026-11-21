import SwiftUI
import AppKit

/// Read-only, selectable text in an NSTextView. Handles very long text without stalling SwiftUI.
struct TextPreview: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 6, height: 8)
            view.setAccessibilityLabel("Content")
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        if !storage.isEqual(to: text) {
            storage.setAttributedString(text)
            view.scrollToBeginningOfDocument(nil)
        }
    }

    static func plain(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.labelColor,
        ])
    }
}
