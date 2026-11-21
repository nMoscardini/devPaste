import AppKit
import SwiftUI
import ApplicationServices

/// A panel that can take keyboard focus without activating devPaste, so the app the user came
/// from stays frontmost and receives the paste.
final class DevPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the floating panel: where it opens, keyboard handling, and when it closes (spec: Panel).
final class PanelController: NSObject, NSWindowDelegate {
    private let panel: DevPanel
    private let model: AppModel
    private var keyMonitor: Any?
    private(set) var target: NSRunningApplication?

    static let defaultSize = NSSize(width: 940, height: 600)
    static let minimumSize = NSSize(width: 620, height: 400)

    init(model: AppModel, theme: ThemeStore) {
        self.model = model
        panel = DevPanel(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                         styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                         backing: .buffered, defer: true)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.minSize = Self.minimumSize
        panel.backgroundColor = .windowBackgroundColor
        panel.delegate = self
        panel.setAccessibilityLabel("devPaste")
        panel.contentView = NSHostingView(rootView: PanelView(model: model, settings: model.settings, queue: model.queue)
            .modifier(Themed(theme: theme, alwaysActive: true)))
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        target = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        model.panelVisible = true
        model.panelWillOpen()
        position()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        // Give SwiftUI a beat to attach the field before focusing it.
        DispatchQueue.main.async { self.model.focusSearch() }
    }

    /// Closes the panel. With unsaved edits it asks first instead (spec: never lose an edit on dismissal).
    func hide() {
        guard panel.isVisible else { return }
        if !model.canClose {
            model.dismissModal()
            return
        }
        forceHide()
    }

    /// Closes without asking, for paste (the edit is being used) and screen lock.
    func forceHide() {
        guard panel.isVisible else { return }
        saveFrame()
        panel.orderOut(nil)
        removeKeyMonitor()
        model.panelVisible = false
        model.previewOverlay = false
    }

    // MARK: Closing

    func windowDidResignKey(_ notification: Notification) {
        // A click outside (or another app taking focus) closes the panel, unless Keep Open is on.
        if !model.settings.keepOpen && model.canClose { forceHide() }
    }

    /// Displays reconnected or rescaled: keep the panel on a visible screen.
    func screensChanged() {
        guard panel.isVisible else { return }
        let frame = panel.frame
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { position() }
    }

    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }
    func windowDidMove(_ notification: Notification) { if panel.isVisible { saveFrame() } }

    // MARK: Placement

    /// Opens on the display holding the focused window, then the pointer's display, then the main
    /// display. Remembers size, and position relative to each display; always clamps to the visible area.
    private func position() {
        guard let screen = focusedWindowScreen() ?? pointerScreen() ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let defaults = UserDefaults.standard

        var size = Self.defaultSize
        if let saved = defaults.string(forKey: "panelSize") {
            let s = NSSizeFromString(saved)
            if s.width >= Self.minimumSize.width, s.height >= Self.minimumSize.height { size = s }
        }
        size.width = min(size.width, visible.width)
        size.height = min(size.height, visible.height)

        var origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height * 0.08)
        if let rel = defaults.dictionary(forKey: "panelPositions")?[Self.key(for: screen)] as? [Double], rel.count == 2 {
            origin = NSPoint(x: visible.minX + rel[0] * visible.width, y: visible.minY + rel[1] * visible.height)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func saveFrame() {
        let frame = panel.frame
        let defaults = UserDefaults.standard
        defaults.set(NSStringFromSize(frame.size), forKey: "panelSize")
        guard let screen = panel.screen else { return }
        let visible = screen.visibleFrame
        guard visible.width > 0, visible.height > 0 else { return }
        var positions = defaults.dictionary(forKey: "panelPositions") ?? [:]
        positions[Self.key(for: screen)] = [Double((frame.minX - visible.minX) / visible.width),
                                            Double((frame.minY - visible.minY) / visible.height)]
        defaults.set(positions, forKey: "panelPositions")
    }

    private static func key(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { "screen-\($0.uint32Value)" } ?? screen.localizedName
    }

    private func pointerScreen() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
    }

    /// The screen under the centre of the target app's focused window. Needs Accessibility; without
    /// it this returns nil and the pointer's display is used.
    private func focusedWindowScreen() -> NSScreen? {
        guard AXIsProcessTrusted(), let pid = target?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXFocusedWindow" as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = windowRef as! AXUIElement
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXPosition" as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, "AXSize" as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        // AX uses top-left origin from the primary display; AppKit uses bottom-left.
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let centre = NSPoint(x: pos.x + size.width / 2, y: primaryHeight - (pos.y + size.height / 2))
        return NSScreen.screens.first { NSMouseInRect(centre, $0.frame, false) }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true if the key was handled. Text editing keys in fields pass through.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // Inside an editor or dialog only Escape is ours; everything else goes to its fields.
        if model.modal != nil {
            if case .snippetEditor(let editor)? = model.modal, editor.recordingShortcut { return false }
            if Int(event.keyCode) == 53 { model.escape(); return true }
            return false
        }

        switch Int(event.keyCode) {
        case 53: // Escape
            model.escape()
            return true
        case 36, 76: // Return, Enter
            if flags == [.command, .shift] { model.openCombine(); return true }
            guard flags.isEmpty || flags == .option else { return false }
            model.pasteFocused(plain: flags == .option)
            return true
        case 125, 126: // Down, Up
            let delta = Int(event.keyCode) == 125 ? 1 : -1
            if flags == [.command, .option] { model.moveSnippet(by: delta); return true }
            guard flags.isEmpty || flags == .shift else { return false }
            model.move(by: delta, extend: flags == .shift)
            return true
        case 116, 121: // Page Up, Page Down
            model.move(by: Int(event.keyCode) == 121 ? 10 : -10)
            return true
        case 48: // Tab switches view
            guard flags.isEmpty || flags == .shift else { return false }
            model.switchSection()
            return true
        case 49: // Space toggles the preview overlay when there is no query to type into
            guard flags.isEmpty, model.query.isEmpty else { return false }
            model.previewOverlay.toggle()
            return true
        case 51 where flags == .command: // Command Delete
            model.delete()
            return true
        default:
            break
        }

        guard flags == .command || flags == [.command, .shift] else { return false }
        if flags == .command, let n = Int(key), (1...9).contains(n) {
            model.pasteNumbered(n)
            return true
        }
        switch (key, flags == .command) {
        case ("f", true): model.focusSearch()
        case ("y", true): model.previewOverlay.toggle()
        case ("p", true): model.togglePinOrFavourite()
        case ("s", true): if model.focused?.clip != nil { model.saveAsSnippet() } else { return false }
        case ("e", true), ("t", true): model.edit()
        case ("n", true): model.switchSection(to: .snippets); model.newSnippet()
        case ("d", true): model.duplicate()
        case ("j", true): model.enqueueSelection()
        case ("l", true): model.modal = .queue
        case ("b", true): model.searchBoth.toggle()
        case (",", true): model.onOpenSettings()
        case ("a", true) where model.query.isEmpty: model.selectAll()
        default: return false
        }
        return true
    }
}
