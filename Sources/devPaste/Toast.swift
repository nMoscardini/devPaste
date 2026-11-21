import AppKit
import SwiftUI

/// A short message near the top of the screen with the pointer, for when the panel has closed
/// (for example "Copied. Press ⌘V in your app."). It never takes focus.
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, seconds: TimeInterval = 2.5) {
        hideWork?.cancel()
        let view = NSHostingView(rootView: ToastView(message: message))
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize

        let p = panel ?? makePanel()
        panel = p
        p.contentView = view
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            p.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 48,
                              width: size.width, height: size.height), display: true)
        }
        p.orderFrontRegardless()
        NSAccessibility.post(element: view, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])

        let work = DispatchWorkItem { Toast.panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return p
    }
}

private struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15)))
            .padding(8)
    }
}
