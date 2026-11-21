import SwiftUI
import DevPasteCore

/// About: version, build, schemas and what is stored, so it is clear which build is running and
/// what it holds. Same layout as devThink's About (serif title, label and value rows, notes).
struct AboutView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    let dataFolder: URL
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("devPaste").font(.system(.largeTitle, design: .serif, weight: .semibold))

            VStack(alignment: .leading, spacing: 14) {
                row("Version", Self.version, note: Self.builtAt.map { "Built \($0). This is what tells two builds apart." })
                row("Schema", "History v\(HistoryStore.schemaVersion), snippets v\(SnippetStore.schemaVersion)",
                    note: "A newer schema than this build is never opened.")

                Divider()
                row("Clipboard", "\(model.stats.count) items, \(model.stats.pinnedCount) pinned, "
                    + ByteCountFormatter.string(fromByteCount: model.stats.bytes, countStyle: .file),
                    note: "Stays on this Mac. Never backed up or sent anywhere.")
                row("Quick Snippets", "\(model.snippetCount) snippets", note: settings.lastBackupMessage)
                row("Data", dataFolder.path)
            }
            .font(.callout)
            .textSelection(.enabled)

            Text("Built by Nino with Claude. Text in images is read on this Mac by Apple's Vision framework.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { model.reload() }
    }

    private func row(_ label: String, _ value: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Text(value).multilineTextAlignment(.trailing)
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    /// When the running executable was written: the build time.
    private static var builtAt: String? {
        guard let url = Bundle.main.executableURL,
              let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
