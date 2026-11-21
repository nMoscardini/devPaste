import SwiftUI
import PDFKit
import DevPasteCore

/// Picks the right preview for a row. Presentation mode hides content (spec: Privacy).
struct ItemPreview: View {
    let item: PanelItem
    @ObservedObject var model: AppModel

    var body: some View {
        if model.presentation {
            EmptyState(symbol: "eye.slash", title: "Hidden in Presentation mode",
                       detail: "Previews are hidden and capture is paused. Turn it off from the menu bar.")
        } else {
            switch item {
            case .clip(let clip):
                ClipPreview(clip: clip, model: model)
                    .environment(\.areaAccent, PanelSection.clipboard.accent)
            case .snippet(let snippet):
                SnippetPreview(snippet: snippet, model: model)
                    .environment(\.areaAccent, PanelSection.snippets.accent)
            }
        }
    }
}

/// Loaded content for a preview: the items, a decoded image, and details.
private struct LoadedContent {
    var items: [CapturedItem] = []
    var image: NSImage?
    var pixelSize: CGSize?
    var formats: [String] = []
    var richText: NSAttributedString?
    var ocr: OCRResult?

    var plainText: String { items.compactMap(\.plainText).joined(separator: "\n") }

    static func load(items: [CapturedItem], decodeImage: Bool) async -> LoadedContent {
        let decoded: (CGImage?, CGSize?) = await Task.detached(priority: .userInitiated) {
            guard decodeImage, let data = firstImageData(items) else { return (nil, nil) }
            return (ImageLoader.downsample(data, maxPixel: 2400), ImageLoader.pixelSize(data))
        }.value
        var content = LoadedContent(items: items)
        content.image = decoded.0.map { NSImage(cgImage: $0, size: .zero) }
        content.pixelSize = decoded.1
        content.formats = Array(Set(items.flatMap { $0.representations.map(\.uti) }))
            .filter { !PBType.internalTypes.contains($0) }.sorted()
        content.richText = items.first?.data(PBType.rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }
        return content
    }

    static func firstImageData(_ items: [CapturedItem]) -> Data? {
        for item in items {
            for uti in PBType.imageTypes {
                if let data = item.data(uti) { return data }
            }
        }
        return nil
    }
}

/// The content area shared by both previews.
private struct ContentBody: View {
    let kind: ContentKind
    let content: LoadedContent
    let loading: Bool

    var body: some View {
        if loading {
            ProgressView().controlSize(.small)
        } else if content.items.isEmpty {
            EmptyState(symbol: "exclamationmark.triangle", title: "Content unavailable",
                       detail: "This item could not be read. It may be damaged. You can delete it.")
        } else {
            switch kind {
            case .image:
                if let image = content.image {
                    Image(nsImage: image).resizable().scaledToFit().padding(12).accessibilityLabel("Image")
                } else {
                    EmptyState(symbol: "photo", title: "Preview failed", detail: "The image could not be decoded. The original is kept.")
                }
            case .pdf:
                if let data = content.items.first?.data(PBType.pdf), let doc = PDFDocument(data: data) {
                    PDFPreview(document: doc)
                } else {
                    TextPreview(text: TextPreview.plain(content.plainText))
                }
            case .file:
                FileList(items: content.items)
            case .richText:
                VStack(alignment: .leading, spacing: 0) {
                    TextPreview(text: content.richText ?? TextPreview.plain(content.plainText))
                    if content.richText == nil {
                        Text("Formatting is kept for paste; shown here as plain text.")
                            .font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                }
            case .text, .link:
                TextPreview(text: TextPreview.plain(content.plainText))
            }
        }
    }
}

// MARK: History item

struct ClipPreview: View {
    let clip: ClipSummary
    @ObservedObject var model: AppModel
    @State private var content = LoadedContent()
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreviewHeader(title: clip.title, detail: detailLine,
                          help: clip.lastCopiedAt.formatted(date: .complete, time: .standard))
            Divider()
            ContentBody(kind: clip.kind, content: content, loading: loading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if clip.kind == .image, let ocr = content.ocr { ocrBar(ocr) }
            Divider()
            actions
        }
        .task(id: "\(clip.id)-\(model.ocrTick)") { await load() }
    }

    private var item: PanelItem { .clip(clip) }

    private var detailLine: String {
        var parts = [clip.sourceName ?? "Unknown app",
                     clip.lastCopiedAt.formatted(date: .abbreviated, time: .shortened),
                     ByteCountFormatter.string(fromByteCount: Int64(clip.byteSize), countStyle: .file)]
        if let size = content.pixelSize { parts.append("\(Int(size.width)) × \(Int(size.height))") }
        if clip.copyCount > 1 { parts.append("copied \(clip.copyCount) times") }
        if !content.formats.isEmpty { parts.append(content.formats.map(formatName).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// OCR state and actions (spec: Pending, Ready, No text found or Failed).
    private func ocrBar(_ ocr: OCRResult) -> some View {
        HStack(spacing: 10) {
            Label("Text in image: \(ocr.state.label)", systemImage: "text.viewfinder")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if ocr.state == .ready, let text = ocr.text {
                Button("Copy text") { copyText(text) }
                    .buttonStyle(SoftCapsule(quiet: true))
                Button("Save text as snippet") { model.saveTextAsSnippet(text) }
                    .buttonStyle(SoftCapsule(quiet: true))
            } else if ocr.state == .failed || ocr.state == .none {
                Button("Try again") { model.retryOCR(clip) }.buttonStyle(SoftCapsule(quiet: true))
            } else if !model.settings.ocrEnabled {
                Text("Text recognition is off in Settings.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        Toast.show("Copied the recognised text.")
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Paste") { model.paste(item) }
                .buttonStyle(PrimaryCapsule())
                .help("Paste (↩)")
            Button("Plain text") { model.paste(item, plain: true) }
                .buttonStyle(SoftCapsule())
                .disabled(content.plainText.isEmpty)
                .help("Paste as plain text (⌥↩)")
            if item.isTextLike {
                Button("Edit") { model.edit(item) }
                    .buttonStyle(SoftCapsule(quiet: true))
                    .help("Edit and transform (⌘E)")
            }
            if clip.kind == .link, let url = URL(string: clip.title) {
                Button("Open link") { NSWorkspace.shared.open(url) }.buttonStyle(SoftCapsule(quiet: true))
            }
            Spacer()
            Menu {
                Button("Save to Quick Snippets") { model.saveAsSnippet(item) }
                Button("Copy") { model.copy(item) }
                Button("Add to queue") { model.select(item.id); model.enqueueSelection() }
                Button(clip.pinned ? "Unpin" : "Pin") { model.togglePinOrFavourite(item) }
                Button("Export…") { model.select(item.id); model.exportSelection() }
                Divider()
                Button("Delete", role: .destructive) { model.delete(item) }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("More actions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func load() async {
        loading = true
        let items = model.content(of: item)
        var loaded = await LoadedContent.load(items: items, decodeImage: clip.kind == .image)
        if clip.kind == .image { loaded.ocr = try? model.store.ocr(id: clip.id) }
        guard !Task.isCancelled else { return }
        content = loaded
        loading = false
    }
}

// MARK: Snippet

struct SnippetPreview: View {
    let snippet: Snippet
    @ObservedObject var model: AppModel
    @State private var content = LoadedContent()
    @State private var loading = true
    @State private var revisions: [SnippetRevisionInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreviewHeader(title: snippet.name, detail: detailLine,
                          help: "Changed " + snippet.updatedAt.formatted(date: .complete, time: .standard))
            Divider()
            ContentBody(kind: snippet.kind, content: content, loading: loading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            actions
        }
        .task(id: "\(snippet.id)-\(snippet.revision)") { await load() }
    }

    private var item: PanelItem { .snippet(snippet) }

    private var detailLine: String {
        var parts = [snippet.categoryName ?? "Uncategorised"]
        if !snippet.tags.isEmpty { parts.append(snippet.tags.map { "#\($0)" }.joined(separator: " ")) }
        if let shortcut = snippet.shortcut { parts.append("Shortcut \(shortcut.label)") }
        parts.append("version \(snippet.revision)")
        parts.append(snippet.useCount == 1 ? "used once" : "used \(snippet.useCount) times")
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Paste") { model.paste(item) }
                .buttonStyle(PrimaryCapsule())
                .help("Paste (↩)")
            Button("Edit") { model.edit(item) }
                .buttonStyle(SoftCapsule())
                .help("Edit (⌘E)")
            Button("Duplicate") { model.duplicate(item) }
                .buttonStyle(SoftCapsule(quiet: true))
                .help("Duplicate (⌘D)")
            Spacer()
            Menu {
                Button("Paste as plain text") { model.paste(item, plain: true) }.disabled(content.plainText.isEmpty)
                Button("Copy") { model.copy(item) }
                Button(snippet.favourite ? "Remove from favourites" : "Add to favourites") { model.togglePinOrFavourite(item) }
                Button("Add to queue") { model.select(item.id); model.enqueueSelection() }
                if revisions.count > 1 {
                    Menu("Restore a previous version") {
                        ForEach(revisions.dropFirst()) { revision in
                            Button("Version \(revision.number), \(revision.createdAt.formatted(date: .abbreviated, time: .shortened))") {
                                model.restoreRevision(snippetID: snippet.id, number: revision.number)
                            }
                        }
                    }
                }
                Button("Export…") { model.select(item.id); model.exportSelection() }
                Divider()
                Button("Delete…", role: .destructive) { model.delete(item) }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("More actions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func load() async {
        loading = true
        let items = model.content(of: item)
        let loaded = await LoadedContent.load(items: items, decodeImage: snippet.kind == .image)
        let history = (try? model.snippets.revisions(id: snippet.id)) ?? []
        guard !Task.isCancelled else { return }
        content = loaded
        revisions = history
        loading = false
    }
}

// MARK: Shared parts

private struct PreviewHeader: View {
    let title: String
    let detail: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).lineLimit(2).textSelection(.enabled)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(help)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func formatName(_ uti: String) -> String {
    switch uti {
    case PBType.plainText: "Text"
    case PBType.rtf: "RTF"
    case PBType.html: "HTML"
    case PBType.png: "PNG"
    case PBType.tiff: "TIFF"
    case PBType.pdf: "PDF"
    case PBType.fileURL: "File"
    case PBType.url: "URL"
    default: uti
    }
}

private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

/// Files: references show where the file is now (moved, or Unavailable with Locate); stored copies
/// show their name and size.
private struct FileList: View {
    let items: [CapturedItem]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    if item.hasStoredFile {
                        storedRow(item)
                    } else if let status = FileResolver.status(of: item) {
                        referenceRow(status)
                    }
                }
            }
            .padding(14)
        }
    }

    private func storedRow(_ item: CapturedItem) -> some View {
        let size = item.data(PBType.fileCopy)?.count ?? 0
        return HStack(spacing: 10) {
            Image(systemName: "doc.fill").font(.title2).foregroundStyle(.secondary).frame(width: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.storedFileName ?? "File").lineLimit(1)
                Text("Stored copy · " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func referenceRow(_ status: FileResolver.Status) -> some View {
        let original: URL = {
            switch status {
            case .available(let u): return u
            case .moved(let from, _): return from
            case .unavailable(let u): return u
            }
        }()
        let current = status.url
        return HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: (current ?? original).path))
                .resizable()
                .frame(width: 32, height: 32)
                .opacity(current == nil ? 0.4 : 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(original.lastPathComponent).lineLimit(1)
                Group {
                    switch status {
                    case .available(let u): Text(u.deletingLastPathComponent().path)
                    case .moved(_, let to): Text("Moved to " + to.deletingLastPathComponent().path)
                    case .unavailable(let u): Text("Was in " + u.deletingLastPathComponent().path)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer()
            if let current {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([current]) }
                    .buttonStyle(SoftCapsule(quiet: true))
            } else {
                Label("Unavailable", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                Button("Locate…") { Locate.run(original: original) }
                    .buttonStyle(SoftCapsule(quiet: true))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Locate a missing file: pick it, and devPaste copies the found file so it can be pasted.
/// The stored history item is not rewritten (sources are immutable).
enum Locate {
    static func run(original: URL) {
        let panel = NSOpenPanel()
        panel.message = "Find \(original.lastPathComponent)"
        panel.prompt = "Use this file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = original.deletingLastPathComponent()
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        Toast.show("Copied \(url.lastPathComponent). Press ⌘V to paste it.")
    }
}
