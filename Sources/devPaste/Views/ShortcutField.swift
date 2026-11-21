import SwiftUI
import DevPasteCore

/// Records a global shortcut. Escape cancels. Needs at least one of ⌘, ⌥ or ⌃.
/// `apply` returns an error message, or nil when the shortcut was accepted.
struct ShortcutField: View {
    let title: String
    let current: String?
    let apply: (SnippetShortcut) -> String?
    var clear: (() -> Void)? = nil
    var onRecordingChange: (Bool) -> Void = { _ in }

    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(recording ? "Press the new shortcut…" : (current ?? "None"))
                    .font(.body.monospaced())
                    .foregroundStyle(recording || current == nil ? .secondary : .primary)
                Button(recording ? "Cancel" : (current == nil ? "Set" : "Change")) { recording ? stop() : start() }
                if let clear, current != nil, !recording {
                    Button("Remove") { clear(); message = nil }
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        message = nil
        recording = true
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            let f = event.modifierFlags
            guard f.contains(.command) || f.contains(.option) || f.contains(.control) else {
                message = "Include ⌘, ⌥ or ⌃."
                return nil
            }
            let mods = HotKey.carbonModifiers(command: f.contains(.command), option: f.contains(.option),
                                              control: f.contains(.control), shift: f.contains(.shift))
            let label = HotKey.label(modifiers: mods, key: (event.charactersIgnoringModifiers ?? "?").uppercased())
            message = apply(SnippetShortcut(keyCode: UInt32(event.keyCode), modifiers: mods, label: label))
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { onRecordingChange(false) }
        recording = false
    }
}
