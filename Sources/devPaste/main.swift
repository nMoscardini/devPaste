import AppKit

// `devPaste --smoke` runs the smoke test against a temporary store and a private pasteboard,
// then exits. It never touches the real clipboard or history.
if CommandLine.arguments.contains("--smoke") {
    exit(Smoke.run())
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
