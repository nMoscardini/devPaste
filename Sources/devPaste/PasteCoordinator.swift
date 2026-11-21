import AppKit
import ApplicationServices
import Carbon.HIToolbox
import DevPasteCore

/// Writes content to the pasteboard and, when it is safe, asks the target app to paste (spec: Paste).
/// Safe means: Accessibility is granted, the target app is still running and frontmost, and no
/// secure field has keyboard input. Otherwise devPaste only copies and says so. It never presses
/// Return or Tab, and never claims the destination accepted the paste.
final class PasteCoordinator {
    enum Outcome {
        case insertRequested
        case copiedOnly(String)
    }

    private let monitor: PasteboardMonitor
    /// Where stored file copies are written out so they can be pasted as files.
    let scratch: URL

    init(monitor: PasteboardMonitor, scratch: URL) {
        self.monitor = monitor
        self.scratch = scratch
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt for Accessibility. Called only when Nino first tries a direct paste.
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Put the items on the general pasteboard. Plain text writes only the text representation.
    /// Returns false if there was nothing suitable to write.
    @discardableResult
    func write(_ items: [CapturedItem], plainText: Bool) -> Bool {
        var objects: [NSPasteboardItem] = []
        let marker = NSPasteboard.PasteboardType(PBType.internalMarker)
        if plainText {
            let text = items.compactMap(\.plainText).joined(separator: "\n")
            guard !text.isEmpty else { return false }
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            item.setData(Data(), forType: marker)
            objects = [item]
        } else {
            for captured in FileResolver.pasteable(items, scratch: scratch) where !captured.representations.isEmpty {
                let item = NSPasteboardItem()
                for rep in captured.representations {
                    item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.uti))
                }
                item.setData(Data(), forType: marker)
                objects.append(item)
            }
            guard !objects.isEmpty else { return false }
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(objects)
        monitor.noteOwnWrite()
        return true
    }

    func paste(_ items: [CapturedItem], plainText: Bool, target: NSRunningApplication?, completion: @escaping (Outcome) -> Void) {
        guard write(items, plainText: plainText) else {
            completion(.copiedOnly("Nothing to paste. A referenced file may have moved or been deleted."))
            return
        }
        guard Self.hasAccessibility else {
            Log.paste.info("paste.copyOnly reason=noAccessibility")
            completion(.copiedOnly("Copied. Press ⌘V in your app."))
            return
        }
        guard let target, !target.isTerminated else {
            Log.paste.info("paste.copyOnly reason=targetGone")
            completion(.copiedOnly("Copied. The app you came from has closed."))
            return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            target.activate()
        }
        waitUntilFrontmost(target, deadline: Date().addingTimeInterval(0.6)) { ok in
            guard ok else {
                Log.paste.info("paste.copyOnly reason=focusChanged")
                completion(.copiedOnly("Copied. Focus moved, so devPaste did not paste."))
                return
            }
            if truth(IsSecureEventInputEnabled()) {
                Log.paste.info("paste.copyOnly reason=secureInput")
                completion(.copiedOnly("Copied. A secure field is active. Press ⌘V yourself."))
                return
            }
            Self.postCommandV()
            Log.paste.info("paste.insertRequested")
            completion(.insertRequested)
        }
    }

    private func waitUntilFrontmost(_ target: NSRunningApplication, deadline: Date, done: @escaping (Bool) -> Void) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
            // A short settle so the target's focused field is ready to receive the event.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                done(NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier)
            }
            return
        }
        if Date() > deadline || target.isTerminated {
            done(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.waitUntilFrontmost(target, deadline: deadline, done: done)
        }
    }

    /// Command V by physical key position. Fine for UK and US layouts (see ENGINEERING_STATE known problems).
    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// IsSecureEventInputEnabled returns a Carbon Boolean; these overloads accept either import.
private func truth(_ b: Bool) -> Bool { b }
private func truth(_ b: DarwinBoolean) -> Bool { b.boolValue }
