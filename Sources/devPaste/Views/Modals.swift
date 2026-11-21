import SwiftUI
import DevPasteCore

/// Hosts an editor or dialog over the panel: a dimmed backdrop and a card.
struct ModalHost: View {
    let modal: Modal
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.themeColours) private var colours

    var body: some View {
        ZStack {
            Color.black.opacity(reduceTransparency ? 0.5 : 0.28)
                .ignoresSafeArea()
                .onTapGesture { model.dismissModal() }
                .accessibilityHidden(true)
            card
                .frame(maxWidth: maxWidth)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(colours.card))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(colours.border))
                .shadow(radius: 20)
                .padding(24)
        }
    }

    private var maxWidth: CGFloat {
        switch modal {
        case .textEditor: 860
        case .confirm, .categoryName: 420
        default: 620
        }
    }

    @ViewBuilder
    private var card: some View {
        switch modal {
        case .snippetEditor(let state):
            SnippetEditorView(state: state, model: model)
                .environment(\.areaAccent, PanelSection.snippets.accent)
        case .textEditor(let state):
            TextEditorView(state: state, model: model)
        case .combine(let state):
            CombineView(state: state, model: model)
        case .queue:
            QueueView(queue: model.queue, model: model)
        case .confirm(let request):
            ConfirmView(request: request, model: model)
        case .categoryName(let state):
            CategoryNameView(state: state, model: model)
                .environment(\.areaAccent, PanelSection.snippets.accent)
        }
    }
}

/// "Discard changes?" bar shown when Escape is pressed on an unsaved edit.
private struct DiscardBar: View {
    let discard: () -> Void
    let keep: () -> Void

    var body: some View {
        AccentCard {
            HStack {
                Label("You have unsaved changes.", systemImage: "exclamationmark.circle")
                Spacer()
                Button("Keep editing", action: keep)
                Button("Discard", role: .destructive, action: discard)
            }
            .font(.callout)
        }
    }
}

// MARK: Snippet editor

struct SnippetEditorView: View {
    @ObservedObject var state: SnippetEditorState
    @ObservedObject var model: AppModel
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(state.isNew ? "New snippet" : "Edit snippet").font(.system(.title2, design: .serif, weight: .semibold))

            Form {
                TextField("Name", text: $state.name).focused($nameFocused)
                Picker("Category", selection: $state.categoryID) {
                    Text("Uncategorised").tag(String?.none)
                    ForEach(model.categories) { Text($0.name).tag(String?.some($0.id)) }
                }
                TextField("Tags", text: $state.tagsText, prompt: Text("Separate with commas"))
                Toggle("Favourite", isOn: $state.favourite)
                ShortcutField(title: "Shortcut", current: state.shortcut?.label,
                              apply: { shortcut in
                                  if let clash = model.shortcutConflict(shortcut, state.snippetID) { return clash }
                                  state.shortcut = shortcut
                                  return nil
                              },
                              clear: { state.shortcut = nil },
                              onRecordingChange: { state.recordingShortcut = $0 })
            }
            .formStyle(.columns)

            contentEditor

            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            }
            if state.confirmDiscard {
                DiscardBar(discard: { model.dismissModal(force: true) }, keep: { state.confirmDiscard = false })
            }

            HStack {
                if !state.revisions.isEmpty, let id = state.snippetID, state.revisions.count > 1 {
                    Menu("Restore version") {
                        ForEach(state.revisions.dropFirst()) { revision in
                            Button("Version \(revision.number), \(revision.createdAt.formatted(date: .abbreviated, time: .shortened))") {
                                model.restoreRevision(snippetID: id, number: revision.number)
                            }
                        }
                    }
                    .fixedSize()
                }
                Spacer()
                Button("Cancel") { model.dismissModal() }
                    .buttonStyle(SoftCapsule(quiet: true))
                Button("Save") { model.saveSnippet(state) }
                    .buttonStyle(PrimaryCapsule())
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(state.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { nameFocused = true }
    }

    @ViewBuilder
    private var contentEditor: some View {
        if state.editsText {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Content").font(.callout.weight(.medium))
                    Spacer()
                    Menu("Transform") {
                        ForEach(TextTransform.allCases) { t in
                            Button(t.label) { state.text = t.apply(state.text) }
                        }
                    }
                    .fixedSize()
                    .disabled(state.text.isEmpty)
                }
                TextEditor(text: $state.text)
                    .font(.body)
                    .frame(minHeight: 140, maxHeight: 260)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                    .accessibilityLabel("Snippet content")
                if state.kind == .richText && state.text != state.originalText {
                    Text("Changing the text saves it as plain text. Formatting is dropped.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if state.hasFiles {
            VStack(alignment: .leading, spacing: 6) {
                Text("Files: " + state.fileURLs.map(\.lastPathComponent).joined(separator: ", "))
                    .lineLimit(2)
                Picker("Keep as", selection: $state.fileMode) {
                    ForEach(SnippetEditorState.FileMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(state.fileMode == .reference
                     ? "A reference points at the file where it is. If the file moves or is deleted, the snippet cannot paste it."
                     : "A copy is stored inside devPaste (up to 50 MB each) and is included in snippet backups.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Label("\(state.kind.label) content is kept exactly as copied.", systemImage: state.kind.symbol)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Edit and transform (history text)

struct TextEditorView: View {
    @ObservedObject var state: TextEditorState
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Edit and transform").font(.system(.title2, design: .serif, weight: .semibold))
                Spacer()
                Menu("Transform") {
                    ForEach(TextTransform.allCases) { t in Button(t.label) { state.apply(t) } }
                }
                .fixedSize()
                Button("Revert") { state.result = state.original; state.lastTransform = nil }
                    .disabled(!state.isDirty)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Before (kept unchanged)").font(.caption).foregroundStyle(.secondary)
                    TextPreview(text: TextPreview.plain(state.original))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.lastTransform.map { "After: \($0.label)" } ?? "After (edit freely)")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $state.result)
                        .font(.body)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.2)))
                        .accessibilityLabel("Edited text")
                }
            }
            .frame(minHeight: 240, maxHeight: 380)

            if state.confirmDiscard {
                DiscardBar(discard: { model.dismissModal(force: true) }, keep: { state.confirmDiscard = false })
            }

            HStack {
                Button("Cancel") { model.dismissModal() }.buttonStyle(SoftCapsule(quiet: true))
                Spacer()
                Button("Save as snippet") { model.saveTextAsSnippet(state.result) }
                    .buttonStyle(SoftCapsule())
                Button("Save to history") { model.saveTextToHistory(state.result) }
                    .buttonStyle(SoftCapsule())
                    .disabled(!state.isDirty)
                    .help("Adds the edited text as a new history item. The original stays.")
                Button("Paste result") { model.pasteText(state.result) }
                    .buttonStyle(PrimaryCapsule())
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
    }
}

// MARK: Combine

struct CombineView: View {
    @ObservedObject var state: CombineState
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Combine \(state.entries.count) items").font(.system(.title2, design: .serif, weight: .semibold))
            List {
                ForEach(Array(state.entries.enumerated()), id: \.element.id) { index, entry in
                    HStack {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                        Text(entry.title).lineLimit(1)
                        Spacer()
                        Button { state.move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(index == 0).accessibilityLabel("Move up")
                        Button { state.move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(index == state.entries.count - 1).accessibilityLabel("Move down")
                    }
                }
            }
            .frame(minHeight: 100, maxHeight: 180)

            HStack {
                Picker("Separator", selection: $state.separator) {
                    ForEach(CombineSeparator.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                if state.separator == .custom {
                    TextField("Separator", text: $state.custom).frame(width: 120)
                }
            }
            Text("Preview").font(.caption).foregroundStyle(.secondary)
            TextPreview(text: TextPreview.plain(state.output))
                .frame(minHeight: 80, maxHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
            HStack {
                Text("Pasted as plain text. Nothing is submitted.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.dismissModal() }.buttonStyle(SoftCapsule(quiet: true))
                Button("Paste") { model.pasteCombined(state) }
                    .buttonStyle(PrimaryCapsule())
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
    }
}

// MARK: Queue

struct QueueView: View {
    @ObservedObject var queue: PasteQueue
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Paste queue").font(.system(.title2, design: .serif, weight: .semibold))
                Spacer()
                Text(queue.progressText ?? "Empty").foregroundStyle(.secondary)
            }
            Toggle("Add every new copy to the queue", isOn: $queue.copyMode)
            if queue.entries.isEmpty {
                Text("Select items and press ⌘J to add them, or turn on the switch above and copy things in order.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List {
                    ForEach(Array(queue.entries.enumerated()), id: \.element.id) { index, entry in
                        HStack {
                            Image(systemName: index < queue.position ? "checkmark.circle.fill" : (index == queue.position ? "arrow.right.circle.fill" : "circle"))
                                .foregroundStyle(index == queue.position ? Color.accentColor : .secondary)
                                .accessibilityLabel(index < queue.position ? "Sent" : (index == queue.position ? "Next" : "Waiting"))
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                            Text(entry.title).lineLimit(1)
                            Spacer()
                            Button { queue.move(at: index, by: -1) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.borderless).disabled(index == 0).accessibilityLabel("Move up")
                            Button { queue.move(at: index, by: 1) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.borderless).disabled(index == queue.entries.count - 1).accessibilityLabel("Move down")
                            Button { queue.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).accessibilityLabel("Remove")
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 240)
            }
            Text(shortcutHelp).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Clear queue", role: .destructive) { queue.clear() }.disabled(!queue.isActive)
                Button("Start again") { queue.restart() }.disabled(queue.entries.isEmpty || queue.position == 0)
                Spacer()
                Button("Done") { model.dismissModal() }.buttonStyle(PrimaryCapsule())
            }
        }
        .padding(20)
    }

    private var shortcutHelp: String {
        let next = model.settings.queueNextShortcut?.label
        let back = model.settings.queueBackShortcut?.label
        guard let next else {
            return "Set a queue shortcut in Settings, Shortcuts. Or use the menu bar icon: Paste next from queue. Each paste sends one item; nothing is submitted. The queue clears after 10 idle minutes, on lock and on quit."
        }
        return "Press \(next) in any app to paste the next item\(back.map { ", \($0) to resend the last one" } ?? ""). The queue clears after 10 idle minutes, on lock and on quit."
    }
}

// MARK: Small dialogs

struct ConfirmView: View {
    let request: ConfirmRequest
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.system(.title3, design: .serif, weight: .semibold))
            Text(request.message).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.dismissModal() }
                    .keyboardShortcut(.cancelAction)
                Button(request.actionLabel, role: request.destructive ? .destructive : nil) {
                    model.dismissModal(force: true)
                    request.action()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

struct CategoryNameView: View {
    @ObservedObject var state: CategoryNameState
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.categoryID == nil ? "New category" : "Rename category").font(.system(.title3, design: .serif, weight: .semibold))
            TextField("Name", text: $state.name).focused($focused).onSubmit { model.saveCategory(state) }
            if let error = state.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { model.dismissModal() }
                Button("Save") { model.saveCategory(state) }
                    .buttonStyle(PrimaryCapsule())
                    .disabled(state.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { focused = true }
    }
}
