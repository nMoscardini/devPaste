import AppKit
import SwiftUI
import DevPasteCore

enum DateFilter: String, CaseIterable, Identifiable {
    case any, today, week, month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .any: "Any time"
        case .today: "Today"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        }
    }

    func since(now: Date = Date()) -> Date? {
        switch self {
        case .any: nil
        case .today: Calendar.current.startOfDay(for: now)
        case .week: now.addingTimeInterval(-7 * 86_400)
        case .month: now.addingTimeInterval(-30 * 86_400)
        }
    }
}

/// State behind the panel. Business rules live in DevPasteCore; this holds what the views show
/// and passes system actions (paste, hot keys, files) to AppController through the hooks below.
final class AppModel: ObservableObject {
    let store: HistoryStore
    let snippets: SnippetStore
    let settings: AppSettings
    let queue: PasteQueue

    // What is shown
    @Published var section: PanelSection = .clipboard
    @Published var query = "" { didSet { if query != oldValue { reload(resetSelection: true) } } }
    @Published var searchBoth = false { didSet { if searchBoth != oldValue { reload(resetSelection: true) } } }
    @Published var filter: KindFilter = .all { didSet { if filter != oldValue { reload(resetSelection: true) } } }
    @Published var sourceFilter: String? = nil { didSet { if sourceFilter != oldValue { reload(resetSelection: true) } } }
    @Published var dateFilter: DateFilter = .any { didSet { if dateFilter != oldValue { reload(resetSelection: true) } } }
    @Published var snippetScope: SnippetScope = .all { didSet { if snippetScope != oldValue { reload(resetSelection: true) } } }

    @Published private(set) var items: [PanelItem] = []
    @Published var selectedID: String? = nil
    @Published private(set) var selection: [String] = []
    private var anchorID: String?

    @Published private(set) var stats = StoreStats(count: 0, bytes: 0, pinnedCount: 0, pinnedBytes: 0)
    @Published private(set) var snippetCount = 0
    @Published private(set) var sources: [SourceApp] = []
    @Published private(set) var categories: [SnippetCategory] = []
    @Published private(set) var loadError: String? = nil

    // Modes and overlays
    @Published var previewOverlay = false
    @Published var modal: Modal? = nil
    @Published private(set) var pausedUntil: Date? = nil
    @Published var locked = false
    @Published var presentation = false
    @Published var fullOfPinned = false
    @Published var focusTick = 0
    /// Bumped when OCR finishes for something, so an open preview refreshes.
    @Published var ocrTick = 0

    var panelVisible = false
    private var savedQueries: [PanelSection: String] = [:]
    private var pauseTimer: Timer?

    // Hooks set by AppController.
    var onCaptureStateChange: () -> Void = {}
    var onPaste: (PanelItem, Bool) -> Void = { _, _ in }
    var onPasteItems: ([CapturedItem], Bool) -> Void = { _, _ in }
    var onCopy: (PanelItem) -> Void = { _ in }
    var onHide: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onSnippetsChanged: () -> Void = {}
    var onSaveTextToHistory: (String) -> Void = { _ in }
    var onEnqueue: ([PanelItem]) -> Void = { _ in }
    var onExport: ([PanelItem]) -> Void = { _ in }
    var onOCRChanged: () -> Void = {}
    /// Returns a message if the shortcut clashes with devPaste's own shortcuts or another snippet.
    var shortcutConflict: (SnippetShortcut, String?) -> String? = { _, _ in nil }

    init(store: HistoryStore, snippets: SnippetStore, settings: AppSettings, queue: PasteQueue) {
        self.store = store
        self.snippets = snippets
        self.settings = settings
        self.queue = queue
    }

    // MARK: Derived

    var focused: PanelItem? { items.first { $0.id == selectedID } }
    /// Selected items in list order ("visible selection order" in the spec).
    var selectedItems: [PanelItem] {
        let chosen = Set(selection)
        let inOrder = items.filter { chosen.contains($0.id) }
        return inOrder.isEmpty ? (focused.map { [$0] } ?? []) : inOrder
    }
    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }
    var isCapturing: Bool { settings.captureStarted && !isPaused && !locked && !presentation }
    var hasActiveFilters: Bool {
        !query.isEmpty || filter != .all || sourceFilter != nil || dateFilter != .any || snippetScope != .all || searchBoth
    }
    var canClose: Bool { !(modal?.isDirty ?? false) }

    var pauseText: String? {
        guard let until = pausedUntil, isPaused else { return nil }
        if until == .distantFuture { return "Capture paused" }
        return "Paused until " + until.formatted(date: .omitted, time: .shortened)
    }

    var scopeLabel: String {
        switch snippetScope {
        case .all: "All"
        case .favourites: "Favourites"
        case .uncategorised: "Uncategorised"
        case .category(let id): categories.first { $0.id == id }?.name ?? "Category"
        }
    }

    // MARK: Loading

    func reload(resetSelection: Bool = false) {
        let q = query
        let both = searchBoth && !SearchQuery.terms(q).isEmpty
        do {
            var clipItems: [PanelItem] = []
            var snippetItems: [PanelItem] = []
            if section == .clipboard || both {
                let request = section == .clipboard
                    ? SearchRequest(query: q, filter: filter, sourceBundleID: sourceFilter, since: dateFilter.since())
                    : SearchRequest(query: q)
                clipItems = try store.search(request).map { PanelItem.clip($0) }
            }
            categories = try snippets.categories()
            if case .category(let id) = snippetScope, !categories.contains(where: { $0.id == id }) { snippetScope = .all }
            if section == .snippets || both {
                let scope = section == .snippets ? snippetScope : .all
                snippetItems = try snippets.list(query: q, scope: scope, sort: settings.snippetSort).map { PanelItem.snippet($0) }
            }
            items = section == .clipboard ? clipItems + snippetItems : snippetItems + clipItems
            stats = try store.stats()
            snippetCount = try snippets.count()
            sources = try store.sources()
            loadError = nil
        } catch {
            items = []
            loadError = "devPaste could not read its data. See Settings, Data."
            Log.store.error("store.readFailed error=\(String(describing: error), privacy: .public)")
        }
        let ids = Set(items.map(\.id))
        if resetSelection || selectedID.map({ !ids.contains($0) }) ?? true {
            selectedID = items.first?.id
            selection = selectedID.map { [$0] } ?? []
            anchorID = selectedID
        } else {
            selection = selection.filter { ids.contains($0) }
            if selection.isEmpty, let id = selectedID { selection = [id] }
        }
    }

    func panelWillOpen() {
        previewOverlay = false
        if !settings.retainQuery {
            savedQueries = [:]
            searchBoth = false
            if query.isEmpty { reload(resetSelection: true) } else { query = "" }
        } else {
            reload(resetSelection: true)
        }
        focusSearch()
    }

    /// Called after a capture commits.
    func didStore(_ result: CommitResult) {
        switch result {
        case .storageFull:
            fullOfPinned = true
            Toast.show("Storage is full of pinned items. Unpin or delete some to keep capturing.")
        case .inserted, .coalesced:
            fullOfPinned = false
        default:
            break
        }
        if panelVisible && modal == nil { reload() } else { stats = (try? store.stats()) ?? stats }
    }

    // MARK: Selection and navigation

    func focusSearch() { focusTick += 1 }

    /// Click: plain selects one, ⌘ toggles, ⇧ extends from the anchor.
    func click(_ item: PanelItem, command: Bool, shift: Bool) {
        if shift, let anchor = anchorID, let a = items.firstIndex(where: { $0.id == anchor }),
           let b = items.firstIndex(where: { $0.id == item.id }) {
            selection = items[min(a, b)...max(a, b)].map(\.id)
            selectedID = item.id
        } else if command {
            if let i = selection.firstIndex(of: item.id), selection.count > 1 {
                selection.remove(at: i)
                selectedID = selection.last
            } else if !selection.contains(item.id) {
                selection.append(item.id)
                selectedID = item.id
            }
            anchorID = item.id
        } else {
            select(item.id)
        }
    }

    func select(_ id: String) {
        selectedID = id
        selection = [id]
        anchorID = id
    }

    func isSelected(_ item: PanelItem) -> Bool { selection.contains(item.id) || item.id == selectedID }

    func selectAll() {
        selection = items.map(\.id)
        if selectedID == nil { selectedID = items.first?.id }
    }

    func move(by delta: Int, extend: Bool = false) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? -1
        let next = min(max(current + delta, 0), items.count - 1)
        let id = items[next].id
        if extend, let anchor = anchorID, let a = items.firstIndex(where: { $0.id == anchor }) {
            selection = items[min(a, next)...max(a, next)].map(\.id)
            selectedID = id
        } else {
            select(id)
        }
    }

    func switchSection(to target: PanelSection? = nil) {
        let next = target ?? (section == .clipboard ? .snippets : .clipboard)
        guard next != section else { return }
        savedQueries[section] = query
        section = next
        let restored = savedQueries[next] ?? ""
        if restored != query { query = restored } else { reload(resetSelection: true) }
        previewOverlay = false
        focusSearch()
    }

    func clearFilters() {
        query = ""
        filter = .all
        sourceFilter = nil
        dateFilter = .any
        snippetScope = .all
        searchBoth = false
        focusSearch()
    }

    /// Escape: close a modal (asking first if it has unsaved edits), then the overlay, then the panel.
    func escape() {
        if modal != nil { dismissModal() }
        else if previewOverlay { previewOverlay = false }
        else { onHide() }
    }

    func dismissModal(force: Bool = false) {
        guard let current = modal else { return }
        if !force && current.isDirty {
            switch current {
            case .snippetEditor(let s):
                if s.confirmDiscard { modal = nil } else { s.confirmDiscard = true }
            case .textEditor(let s):
                if s.confirmDiscard { modal = nil } else { s.confirmDiscard = true }
            default:
                modal = nil
            }
        } else {
            modal = nil
        }
        if modal == nil { focusSearch() }
    }

    // MARK: Paste and copy

    func pasteFocused(plain: Bool) {
        let chosen = selectedItems
        if chosen.count > 1 { openCombine(); return }
        guard let item = chosen.first else { return }
        onPaste(item, plain)
    }

    func pasteNumbered(_ n: Int) {
        guard n >= 1, n <= min(items.count, 9) else { return }
        onPaste(items[n - 1], false)
    }

    func paste(_ item: PanelItem, plain: Bool = false) { onPaste(item, plain) }
    func copy(_ item: PanelItem) { onCopy(item) }

    /// The stored content behind an item.
    func content(of item: PanelItem) -> [CapturedItem] {
        switch item {
        case .clip(let c): (try? store.items(id: c.id)) ?? []
        case .snippet(let s): (try? snippets.items(id: s.id)) ?? []
        }
    }

    // MARK: History actions

    func togglePinOrFavourite(_ item: PanelItem? = nil) {
        guard let item = item ?? focused else { return }
        switch item {
        case .clip(let c): _ = try? store.setPinned(id: c.id, pinned: !c.pinned)
        case .snippet(let s): _ = try? snippets.setFavourite(id: s.id, !s.favourite)
        }
        reload()
    }

    /// History items go at once. Snippets are permanent, so they ask first.
    func delete(_ item: PanelItem? = nil) {
        let targets = item.map { [$0] } ?? selectedItems
        guard !targets.isEmpty else { return }
        let clipIDs = targets.compactMap { $0.clip?.id }
        let snippetList = targets.compactMap(\.snippet)
        let index = items.firstIndex { $0.id == targets[0].id } ?? 0
        if !clipIDs.isEmpty {
            _ = try? store.delete(ids: clipIDs)
            reload()
            if !items.isEmpty { select(items[min(index, items.count - 1)].id) }
        }
        if !snippetList.isEmpty {
            let names = snippetList.count == 1 ? "“\(snippetList[0].name)”" : "\(snippetList.count) snippets"
            modal = .confirm(ConfirmRequest(
                title: "Delete \(names)?",
                message: "Snippets are permanent. Their saved versions go too. Backups are not affected.",
                actionLabel: "Delete", destructive: true) { [weak self] in
                    guard let self else { return }
                    for s in snippetList { _ = try? self.snippets.delete(id: s.id) }
                    self.onSnippetsChanged()
                    self.reload()
                })
        }
    }

    func deleteRecent(seconds: TimeInterval) {
        _ = try? store.deleteCopied(since: Date().addingTimeInterval(-seconds))
        reload(resetSelection: true)
    }

    func deleteAll(includePinned: Bool) {
        _ = try? store.deleteAll(includePinned: includePinned)
        reload(resetSelection: true)
    }

    // MARK: Snippets

    func newSnippet() {
        modal = .snippetEditor(SnippetEditorState(snippet: nil, items: [], name: "", categoryID: currentCategoryID))
    }

    /// Save to Quick Snippets (⌘S): an independent copy of a history item.
    func saveAsSnippet(_ item: PanelItem? = nil) {
        guard let item = item ?? focused, item.clip != nil else { return }
        let stored = content(of: item)
        guard !stored.isEmpty else { Toast.show("That item could not be read."); return }
        modal = .snippetEditor(SnippetEditorState(snippet: nil, items: stored,
                                                  name: SnippetDraft.suggestedName(for: stored), categoryID: nil))
    }

    func saveTextAsSnippet(_ text: String) {
        let items = [CapturedItem(representations: [Representation(uti: PBType.plainText, data: Data(text.utf8))])]
        modal = .snippetEditor(SnippetEditorState(snippet: nil, items: items,
                                                  name: SnippetDraft.suggestedName(for: items), categoryID: nil))
    }

    /// ⌘E: snippets open the snippet editor; history text opens edit and transform.
    func edit(_ item: PanelItem? = nil) {
        guard let item = item ?? focused else { return }
        switch item {
        case .snippet(let s):
            let stored = content(of: item)
            let revisions = (try? snippets.revisions(id: s.id)) ?? []
            modal = .snippetEditor(SnippetEditorState(snippet: s, items: stored, name: s.name,
                                                      categoryID: s.categoryID, revisions: revisions))
        case .clip:
            guard item.isTextLike else { Toast.show("Only text can be edited. Images and files are kept as they are."); return }
            let text = content(of: item).compactMap(\.plainText).joined(separator: "\n")
            modal = .textEditor(TextEditorState(source: item, original: text))
        }
    }

    @discardableResult
    func saveSnippet(_ state: SnippetEditorState) -> Bool {
        state.error = nil
        do {
            let draft = SnippetDraft(name: state.name, categoryID: state.categoryID, tags: state.tags,
                                     favourite: state.favourite, items: try state.draftItems())
            if let shortcut = state.shortcut, let clash = shortcutConflict(shortcut, state.snippetID) {
                state.error = clash
                return false
            }
            let id: String
            if let existing = state.snippetID {
                try snippets.update(id: existing, with: draft)
                id = existing
            } else {
                id = try snippets.create(draft)
            }
            try snippets.setShortcut(id: id, state.shortcut)
            modal = nil
            onSnippetsChanged()
            reload()
            if section == .snippets { select("s:" + id) }
            Toast.show("Saved “\(draft.name.trimmingCharacters(in: .whitespaces))” to Quick Snippets.")
            focusSearch()
            return true
        } catch {
            state.error = (error as? SnippetError)?.description ?? error.localizedDescription
            return false
        }
    }

    func restoreRevision(snippetID: String, number: Int) {
        do {
            try snippets.restore(id: snippetID, revision: number)
            modal = nil
            reload()
            Toast.show("Restored version \(number). It is now the newest version.")
        } catch {
            Toast.show((error as? SnippetError)?.description ?? "That version could not be restored.")
        }
    }

    func duplicate(_ item: PanelItem? = nil) {
        guard let s = (item ?? focused)?.snippet else { return }
        if let id = try? snippets.duplicate(id: s.id) {
            reload()
            select("s:" + id)
        }
    }

    func moveSnippet(by delta: Int) {
        guard let s = focused?.snippet else { return }
        _ = try? snippets.move(id: s.id, by: delta)
        reload()
    }

    var currentCategoryID: String? {
        if case .category(let id) = snippetScope { return id }
        return nil
    }

    func newCategory() { modal = .categoryName(CategoryNameState(categoryID: nil, name: "")) }

    func renameCategory(_ category: SnippetCategory) {
        modal = .categoryName(CategoryNameState(categoryID: category.id, name: category.name))
    }

    func saveCategory(_ state: CategoryNameState) {
        do {
            if let id = state.categoryID {
                try snippets.renameCategory(id: id, to: state.name)
                modal = nil
                reload()
            } else {
                let created = try snippets.addCategory(name: state.name)
                modal = nil
                if section == .snippets { snippetScope = .category(created.id) } else { reload() }
            }
        } catch {
            state.error = (error as? SnippetError)?.description ?? error.localizedDescription
        }
    }

    func deleteCategory(_ category: SnippetCategory) {
        modal = .confirm(ConfirmRequest(
            title: "Delete the category “\(category.name)”?",
            message: "Its snippets move to Uncategorised. No snippet is deleted.",
            actionLabel: "Delete category", destructive: true) { [weak self] in
                guard let self else { return }
                _ = try? self.snippets.deleteCategory(id: category.id)
                if self.snippetScope == .category(category.id) { self.snippetScope = .all } else { self.reload() }
            })
    }

    // MARK: Combine, queue, export

    func openCombine() {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        if chosen.contains(where: { !$0.isTextLike }) {
            Toast.show("Combined paste joins text only. Deselect images and files first.")
            return
        }
        let entries = chosen.map { item in
            CombineState.Entry(id: item.id, title: item.title,
                               text: content(of: item).compactMap(\.plainText).joined(separator: "\n"))
        }
        modal = .combine(CombineState(entries: entries))
    }

    func pasteCombined(_ state: CombineState) {
        pasteText(state.output)
    }

    func enqueueSelection() {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        onEnqueue(chosen)
    }

    func exportSelection() { onExport(selectedItems) }

    // MARK: Text editor results

    func pasteText(_ text: String) {
        modal = nil
        onPasteItems([CapturedItem(representations: [Representation(uti: PBType.plainText, data: Data(text.utf8))])], true)
    }

    func saveTextToHistory(_ text: String) {
        modal = nil
        onSaveTextToHistory(text)
    }

    // MARK: OCR

    func retryOCR(_ clip: ClipSummary) {
        _ = try? store.retryOCR(id: clip.id)
        ocrTick += 1
        onOCRChanged()
    }

    // MARK: Capture state

    func startCapture() {
        settings.captureStarted = true
        onCaptureStateChange()
    }

    /// nil seconds means until resumed.
    func pause(seconds: TimeInterval?) {
        pauseTimer?.invalidate()
        pausedUntil = seconds.map { Date().addingTimeInterval($0) } ?? .distantFuture
        if let seconds {
            let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in self?.resume() }
            RunLoop.main.add(t, forMode: .common)
            pauseTimer = t
        }
        onCaptureStateChange()
    }

    func resume() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        pausedUntil = nil
        onCaptureStateChange()
    }

    /// Presentation mode hides previews and pauses capture (spec: Privacy).
    func setPresentation(_ on: Bool) {
        presentation = on
        previewOverlay = false
        onCaptureStateChange()
        Toast.show(on ? "Presentation mode on: previews hidden, capture paused." : "Presentation mode off.")
    }
}
