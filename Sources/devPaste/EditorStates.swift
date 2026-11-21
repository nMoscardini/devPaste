import Foundation
import DevPasteCore

/// A confirmation shown inside the panel (an alert would steal focus and close the panel).
struct ConfirmRequest {
    let title: String
    let message: String
    let actionLabel: String
    let destructive: Bool
    let action: () -> Void
}

final class CategoryNameState: ObservableObject {
    let categoryID: String?
    @Published var name: String
    @Published var error: String? = nil

    init(categoryID: String?, name: String) {
        self.categoryID = categoryID
        self.name = name
    }
}

/// The snippet editor: name, category, tags, favourite, content and an optional shortcut (spec: Quick Snippets).
final class SnippetEditorState: ObservableObject {
    enum FileMode: String, CaseIterable, Identifiable {
        case reference, copy
        var id: String { rawValue }
        var label: String { self == .reference ? "Keep a reference" : "Store a copy" }
    }

    let snippetID: String?
    let kind: ContentKind
    let originalItems: [CapturedItem]
    let originalText: String
    let fileURLs: [URL]
    let revisions: [SnippetRevisionInfo]

    @Published var name: String
    @Published var categoryID: String? = nil
    @Published var tagsText: String
    @Published var favourite: Bool
    @Published var text: String
    @Published var fileMode: FileMode = .reference
    @Published var shortcut: SnippetShortcut? = nil
    @Published var error: String? = nil
    @Published var confirmDiscard = false
    @Published var recordingShortcut = false

    private let initialName: String
    private let initialCategory: String?
    private let initialTags: String
    private let initialFavourite: Bool
    private let initialShortcut: SnippetShortcut?

    var isNew: Bool { snippetID == nil }
    /// Text, rich text and links are edited as text. Images and files keep their content as it is.
    var editsText: Bool { [.text, .richText, .link].contains(kind) || originalItems.isEmpty }
    var hasFiles: Bool { !fileURLs.isEmpty }

    var isDirty: Bool {
        name != initialName || categoryID != initialCategory || tagsText != initialTags || favourite != initialFavourite
            || text != originalText || shortcut != initialShortcut || (hasFiles && fileMode != .reference)
    }

    var tags: [String] { tagsText.split(separator: ",").map { String($0) } }

    init(snippet: Snippet?, items: [CapturedItem], name: String, categoryID: String?, revisions: [SnippetRevisionInfo] = []) {
        snippetID = snippet?.id
        let tx = CapturedTransaction(items: items, sourceBundleID: nil, sourceName: nil)
        kind = items.isEmpty ? .text : tx.kind
        originalItems = items
        originalText = tx.plainText
        fileURLs = items.compactMap(\.fileURL)
        self.revisions = revisions
        self.name = name
        self.categoryID = categoryID
        tagsText = snippet?.tags.joined(separator: ", ") ?? ""
        favourite = snippet?.favourite ?? false
        text = tx.plainText
        shortcut = snippet?.shortcut
        initialName = name
        initialCategory = categoryID
        initialTags = snippet?.tags.joined(separator: ", ") ?? ""
        initialFavourite = snippet?.favourite ?? false
        initialShortcut = snippet?.shortcut
    }

    /// The content to save. Editing the text of rich text saves plain text (the editor says so).
    func draftItems() throws -> [CapturedItem] {
        if editsText {
            if !originalItems.isEmpty && text == originalText { return originalItems.map(\.withoutBookmark) }
            return [CapturedItem(representations: [Representation(uti: PBType.plainText, data: Data(text.utf8))])]
        }
        if hasFiles && fileMode == .copy {
            return try fileURLs.map(Self.storedCopy)
        }
        return originalItems
    }

    /// Reads a file into the snippet, so the snippet keeps working if the original moves or goes.
    static func storedCopy(of url: URL) throws -> CapturedItem {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw SnippetError(description: "\(url.lastPathComponent) is no longer there.")
        }
        guard !isDirectory.boolValue else {
            throw SnippetError(description: "\(url.lastPathComponent) is a folder. Folders can only be kept as a reference.")
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= RetentionPolicy.maxTransactionBytes else {
            throw SnippetError(description: "\(url.lastPathComponent) is larger than 50 MB.")
        }
        let data = try Data(contentsOf: url)
        return CapturedItem(representations: [
            Representation(uti: PBType.fileCopy, data: data),
            Representation(uti: PBType.fileName, data: Data(url.lastPathComponent.utf8)),
        ])
    }
}

/// Edit and transform text from history (spec: Editing and transforms). The original stays on the
/// left, unchanged; the result on the right can be edited and transformed.
final class TextEditorState: ObservableObject {
    let source: PanelItem
    let original: String
    @Published var result: String
    @Published var lastTransform: TextTransform? = nil
    @Published var confirmDiscard = false

    var isDirty: Bool { result != original }

    init(source: PanelItem, original: String) {
        self.source = source
        self.original = original
        self.result = original
    }

    func apply(_ transform: TextTransform) {
        result = transform.apply(result)
        lastTransform = transform
    }
}

/// Combined paste: selected text items joined in order with a chosen separator (spec: Combined paste).
final class CombineState: ObservableObject {
    struct Entry: Identifiable {
        let id: String
        let title: String
        let text: String
    }

    @Published var entries: [Entry]
    @Published var separator: CombineSeparator = .newLine
    @Published var custom = " - "

    init(entries: [Entry]) {
        self.entries = entries
    }

    var output: String {
        CombineSeparator.combine(entries.map(\.text), separator: separator, custom: custom)
    }

    func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard entries.indices.contains(index), entries.indices.contains(target) else { return }
        entries.swapAt(index, target)
    }
}

enum Modal {
    case snippetEditor(SnippetEditorState)
    case textEditor(TextEditorState)
    case combine(CombineState)
    case queue
    case confirm(ConfirmRequest)
    case categoryName(CategoryNameState)

    var isDirty: Bool {
        switch self {
        case .snippetEditor(let s): s.isDirty
        case .textEditor(let s): s.isDirty
        default: false
        }
    }
}
