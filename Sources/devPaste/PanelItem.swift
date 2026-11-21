import Foundation
import DevPasteCore

/// One row in the panel: a history item or a snippet. Lets both views, and "Search both views",
/// share one list, one preview and one set of keyboard actions.
enum PanelItem: Identifiable, Equatable {
    case clip(ClipSummary)
    case snippet(Snippet)

    var id: String {
        switch self {
        case .clip(let c): "c:" + c.id
        case .snippet(let s): "s:" + s.id
        }
    }

    var clip: ClipSummary? {
        if case .clip(let c) = self { return c }
        return nil
    }

    var snippet: Snippet? {
        if case .snippet(let s) = self { return s }
        return nil
    }

    var kind: ContentKind {
        switch self {
        case .clip(let c): c.kind
        case .snippet(let s): s.kind
        }
    }

    var title: String {
        switch self {
        case .clip(let c): c.title
        case .snippet(let s): s.name
        }
    }

    /// Text, rich text and links can be edited, transformed and combined.
    var isTextLike: Bool { [.text, .richText, .link].contains(kind) }
}

/// The paste queue (spec: Paste queue). Entries are snapshots taken when added, so later edits or
/// deletes do not change what the queue pastes. Never saved; cleared on lock, quit or 10 idle minutes.
final class PasteQueue: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let title: String
        let kind: ContentKind
        let items: [CapturedItem]
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var position = 0
    /// While on, every new copy is added to the queue.
    @Published var copyMode = false { didSet { touch() } }

    private var expiry: Timer?
    static let idleLimit: TimeInterval = 600

    var isActive: Bool { !entries.isEmpty || copyMode }
    var next: Entry? { position < entries.count ? entries[position] : nil }
    var lastSent: Entry? { position > 0 && position <= entries.count ? entries[position - 1] : nil }

    var progressText: String? {
        if entries.isEmpty { return copyMode ? "Queue: copying" : nil }
        if position >= entries.count { return "Queue complete" }
        return "Queue \(position + 1) of \(entries.count)"
    }

    var shortProgress: String? {
        guard !entries.isEmpty else { return nil }
        return "\(min(position + 1, entries.count))/\(entries.count)"
    }

    func add(_ new: [Entry]) {
        guard !new.isEmpty else { return }
        entries += new
        touch()
    }

    func remove(at index: Int) {
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
        if index < position { position -= 1 }
        position = min(position, entries.count)
        touch()
    }

    func move(at index: Int, by delta: Int) {
        let target = index + delta
        guard entries.indices.contains(index), entries.indices.contains(target) else { return }
        entries.swapAt(index, target)
        touch()
    }

    func advance() {
        position = min(position + 1, entries.count)
        touch()
    }

    func restart() {
        position = 0
        touch()
    }

    func clear() {
        entries = []
        position = 0
        copyMode = false
        expiry?.invalidate()
        expiry = nil
    }

    private func touch() {
        expiry?.invalidate()
        guard !entries.isEmpty || copyMode else { return }
        let t = Timer(timeInterval: Self.idleLimit, repeats: false) { [weak self] _ in self?.clear() }
        RunLoop.main.add(t, forMode: .common)
        expiry = t
    }
}
