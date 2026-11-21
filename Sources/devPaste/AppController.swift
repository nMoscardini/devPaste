import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import DevPasteCore

/// Wires the parts together: stores, capture, paste, queue, OCR, backups, panel, menu bar, hot keys.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var settings: AppSettings!
    private var store: HistoryStore!
    private var snippets: SnippetStore!
    private var model: AppModel!
    private var queue: PasteQueue!
    private var monitor: PasteboardMonitor!
    private var sources: SourceTracker!
    private var paster: PasteCoordinator!
    private var panel: PanelController!
    private var ocr: OCRService!
    private var backup: SnippetBackupService!
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var carousel: CarouselController!
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var theme: ThemeStore!
    private var timers: [Timer] = []
    private var cancellables = Set<AnyCancellable>()

    private var panelHotKey: HotKey?
    private var queueNextHotKey: HotKey?
    private var queueBackHotKey: HotKey?
    private var snippetHotKeys: [String: HotKey] = [:]
    /// Snippet shortcuts that could not be registered, by snippet id.
    private var shortcutProblems: [String: String] = [:]

    /// Capture commits and payload reads happen here, never on the main thread.
    private let work = DispatchQueue(label: "com.nino.devPaste.work", qos: .userInitiated)

    // MARK: Folders

    static var supportFolder: URL {
        if let override = ProcessInfo.processInfo.environment["DEVPASTE_STORE"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("devPaste", isDirectory: true)
    }
    static var historyFolder: URL { supportFolder.appendingPathComponent("history", isDirectory: true) }
    static var snippetFolder: URL { supportFolder.appendingPathComponent("snippets", isDirectory: true) }
    static var backupFolder: URL { supportFolder.appendingPathComponent("backups", isDirectory: true) }
    static var scratchFolder: URL { supportFolder.appendingPathComponent("paste-files", isDirectory: true) }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = AppSettings()
        theme = ThemeStore()
        do {
            store = try HistoryStore(directory: Self.historyFolder, retention: settings.retentionPolicy)
            snippets = try SnippetStore(directory: Self.snippetFolder)
        } catch {
            Log.store.fault("store.openFailed error=\(String(describing: error), privacy: .public)")
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "devPaste could not open its data"
            alert.informativeText = "\(error)\n\nThe files were left untouched in \(Self.supportFolder.path)."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        // History and temporary paste files are never backed up. Snippets and their backups are.
        Self.excludeFromBackup(Self.historyFolder)
        try? FileManager.default.createDirectory(at: Self.scratchFolder, withIntermediateDirectories: true)
        Self.excludeFromBackup(Self.scratchFolder)
        FileResolver.cleanScratch(Self.scratchFolder)

        queue = PasteQueue()
        model = AppModel(store: store, snippets: snippets, settings: settings, queue: queue)
        monitor = PasteboardMonitor()
        sources = SourceTracker()
        paster = PasteCoordinator(monitor: monitor, scratch: Self.scratchFolder)
        panel = PanelController(model: model, theme: theme)
        carousel = CarouselController(model: model, settings: settings, theme: theme)
        carousel.onCopy = { [unowned self] item in self.model.copy(item) }
        ocr = OCRService(store: store)
        backup = SnippetBackupService(store: snippets, settings: settings, localFolder: Self.backupFolder)

        wireCapture()
        wireModel()
        setupStatusItem()
        observeSystem()
        observeSettings()

        monitor.start()
        applyCaptureState()
        startTimers()

        ocr.enabled = settings.ocrEnabled
        ocr.onUpdate = { [weak self] _ in self?.model.ocrTick += 1 }
        ocr.kick()

        let panelOK = registerPanelHotKey()
        registerQueueHotKeys()
        rebuildSnippetHotKeys()
        backup.runIfDue()
        Log.app.info("app.launched hotKey=\(panelOK, privacy: .public) accessibility=\(PasteCoordinator.hasAccessibility, privacy: .public)")

        DispatchQueue.main.async {
            if !self.settings.onboarded { self.runOnboarding() }
            if !panelOK { self.reportHotKeyTaken() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        queue?.clear()
    }

    private static func excludeFromBackup(_ folder: URL) {
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do { try url.setResourceValues(values) } catch {
            Log.store.error("store.backupExclusionFailed error=\(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Capture

    private func wireCapture() {
        monitor.policy = { [unowned self] in self.settings.capturePolicy }
        monitor.attribution = { [unowned self] in self.sources.attribute() }
        monitor.onSkipped = { message in Toast.show(message) }
        monitor.onTransaction = { [unowned self] tx in
            let keepDuplicates = self.settings.keepDuplicates
            self.work.async {
                let result: CommitResult
                do {
                    result = try self.store.commit(tx, keepDuplicates: keepDuplicates)
                    if case .inserted = result { try self.store.enforceRetention() }
                } catch {
                    Log.store.error("store.commitFailed error=\(String(describing: error), privacy: .public)")
                    return
                }
                Log.capture.info("capture.committed kind=\(tx.kind.rawValue, privacy: .public) bytes=\(tx.byteSize, privacy: .public) result=\(Self.label(result), privacy: .public)")
                DispatchQueue.main.async {
                    self.model.didStore(result)
                    if self.queue.copyMode, Self.isStored(result) {
                        self.queue.add([PasteQueue.Entry(title: tx.title, kind: tx.kind, items: tx.items)])
                    }
                    if tx.kind == .image { self.ocr.kick() }
                    self.updateStatusIcon()
                }
            }
        }
    }

    private static func isStored(_ result: CommitResult) -> Bool {
        switch result {
        case .inserted, .coalesced: true
        default: false
        }
    }

    private static func label(_ result: CommitResult) -> String {
        switch result {
        case .inserted: "inserted"
        case .coalesced: "coalesced"
        case .tooLarge: "tooLarge"
        case .storageFull: "storageFull"
        case .empty: "empty"
        }
    }

    /// Capture runs only when started, not paused, not locked and not presenting. Turning it on
    /// never imports what was copied while it was off.
    private func applyCaptureState() {
        let shouldCapture = model.isCapturing
        if shouldCapture && !monitor.isCapturing { monitor.resync() }
        monitor.isCapturing = shouldCapture
        updateStatusIcon()
        model.objectWillChange.send()
    }

    private func startTimers() {
        work.async { [store] in
            _ = try? store?.enforceRetention()
            _ = try? store?.collectOrphanBlobs()
        }
        let hourly = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.backup.runIfDue()
            self.work.async {
                if let result = try? self.store.enforceRetention(), result.deleted > 0 {
                    Log.store.info("store.retention deleted=\(result.deleted, privacy: .public)")
                    DispatchQueue.main.async { if self.model.panelVisible { self.model.reload() } }
                }
            }
        }
        RunLoop.main.add(hourly, forMode: .common)
        timers.append(hourly)
    }

    // MARK: Model hooks

    private func wireModel() {
        model.onHide = { [unowned self] in self.panel.hide() }
        model.onOpenSettings = { [unowned self] in
            self.panel.hide()
            self.showSettings()
        }
        model.onCaptureStateChange = { [unowned self] in self.applyCaptureState() }
        model.onCopy = { [unowned self] item in
            self.loadItems(item) { items in
                if self.paster.write(items, plainText: false) { Toast.show("Copied.") }
            }
        }
        model.onPaste = { [unowned self] item, plain in self.paste(item, plain: plain) }
        model.onPasteItems = { [unowned self] items, plain in
            let target = self.panel.target
            self.panel.forceHide()
            self.deliver(items, plain: plain, target: target, onInserted: nil)
        }
        model.onSnippetsChanged = { [unowned self] in self.rebuildSnippetHotKeys() }
        model.onSaveTextToHistory = { [unowned self] text in self.saveTextToHistory(text) }
        model.onEnqueue = { [unowned self] items in self.enqueue(items) }
        model.onExport = { [unowned self] items in self.export(items) }
        model.onOCRChanged = { [unowned self] in self.ocr.kick() }
        model.shortcutConflict = { [unowned self] shortcut, snippetID in self.conflict(for: shortcut, snippetID: snippetID) }
        queue.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusIcon() }
        }.store(in: &cancellables)
    }

    private func loadItems(_ item: PanelItem, then: @escaping ([CapturedItem]) -> Void) {
        work.async {
            let items = self.model.content(of: item)
            DispatchQueue.main.async {
                if items.isEmpty { Toast.show("That item could not be read.") } else { then(items) }
            }
        }
    }

    private func paste(_ item: PanelItem, plain: Bool) {
        let target = panel.target
        panel.forceHide()
        loadItems(item) { items in
            self.deliver(items, plain: plain, target: target) {
                self.work.async {
                    switch item {
                    case .clip(let c): try? self.store.notePasteRequested(id: c.id)
                    case .snippet(let s): try? self.snippets.noteUsed(id: s.id)
                    }
                }
            }
        }
    }

    /// Writes and, when safe, pastes. Asks for Accessibility the first time direct paste is tried.
    private func deliver(_ items: [CapturedItem], plain: Bool, target: NSRunningApplication?, onInserted: (() -> Void)?) {
        if !PasteCoordinator.hasAccessibility && !settings.accessibilityPrompted {
            settings.accessibilityPrompted = true
            PasteCoordinator.requestAccessibility()
        }
        paster.paste(items, plainText: plain, target: target) { outcome in
            switch outcome {
            case .insertRequested: onInserted?()
            case .copiedOnly(let message): Toast.show(message)
            }
        }
    }

    /// An edited text saved as a new history item. The original is not changed.
    private func saveTextToHistory(_ text: String) {
        let tx = CapturedTransaction(items: [CapturedItem(representations: [Representation(uti: PBType.plainText, data: Data(text.utf8))])],
                                     sourceBundleID: Bundle.main.bundleIdentifier, sourceName: "Edited in devPaste")
        work.async {
            let result = try? self.store.commit(tx)
            DispatchQueue.main.async {
                if let result { self.model.didStore(result) }
                self.model.reload(resetSelection: true)
                Toast.show("Saved the edited text to history.")
            }
        }
    }

    // MARK: Queue

    private func enqueue(_ items: [PanelItem]) {
        // Spec: queue order defaults to capture order, oldest first. Snippets keep list order after history.
        let clips = items.compactMap(\.clip).sorted { $0.capturedAt < $1.capturedAt }.map { PanelItem.clip($0) }
        let others = items.filter { $0.clip == nil }
        let ordered = clips + others
        let entries = ordered.compactMap { item -> PasteQueue.Entry? in
            let content = model.content(of: item)
            return content.isEmpty ? nil : PasteQueue.Entry(title: item.title, kind: item.kind, items: content)
        }
        queue.add(entries)
        Toast.show(entries.count == 1 ? "Added 1 item to the queue." : "Added \(entries.count) items to the queue.")
    }

    /// Paste the next queue item into whatever app is in front. One item per press; never submits.
    func queueNext() {
        guard let entry = queue.next else {
            Toast.show(queue.entries.isEmpty ? "The paste queue is empty." : "Queue complete.")
            return
        }
        panel.forceHide()
        let target = frontmostOtherApp()
        deliver(entry.items, plain: false, target: target) {
            self.queue.advance()
            Toast.show(self.queue.next == nil ? "Queue complete." : "\(self.queue.progressText ?? "") · insert requested")
        }
    }

    /// Resend the item just sent, for when the target did not accept it.
    func queueBack() {
        guard let entry = queue.lastSent else { Toast.show("Nothing has been sent from the queue yet."); return }
        panel.forceHide()
        deliver(entry.items, plain: false, target: frontmostOtherApp()) {
            Toast.show("Resent: \(entry.title.prefix(40))")
        }
    }

    private func frontmostOtherApp() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        return front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
    }

    // MARK: Hot keys

    @discardableResult
    private func registerPanelHotKey() -> Bool {
        panelHotKey = nil
        panelHotKey = HotKey(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers) { [weak self] in
            self?.panel.toggle()
        }
        return panelHotKey != nil
    }

    private func registerQueueHotKeys() {
        queueNextHotKey = settings.queueNextShortcut.flatMap { s in
            HotKey(keyCode: s.keyCode, modifiers: s.modifiers) { [weak self] in self?.queueNext() }
        }
        queueBackHotKey = settings.queueBackShortcut.flatMap { s in
            HotKey(keyCode: s.keyCode, modifiers: s.modifiers) { [weak self] in self?.queueBack() }
        }
    }

    private func rebuildSnippetHotKeys() {
        snippetHotKeys = [:]
        shortcutProblems = [:]
        guard settings.snippetShortcutsEnabled, let list = try? snippets.shortcuts() else { return }
        for entry in list {
            if let clash = ownShortcutClash(entry.shortcut) {
                shortcutProblems[entry.id] = clash
                continue
            }
            let id = entry.id
            if let key = HotKey(keyCode: entry.shortcut.keyCode, modifiers: entry.shortcut.modifiers, action: { [weak self] in
                self?.pasteSnippetFromShortcut(id)
            }) {
                snippetHotKeys[id] = key
            } else {
                shortcutProblems[id] = "Taken by another app"
            }
        }
    }

    private func pasteSnippetFromShortcut(_ id: String) {
        guard let snippet = try? snippets.snippet(id: id) else { return }
        let target = frontmostOtherApp()
        panel.forceHide()
        loadItems(.snippet(snippet)) { items in
            self.deliver(items, plain: false, target: target) {
                self.work.async { try? self.snippets.noteUsed(id: id) }
            }
        }
    }

    private func same(_ a: SnippetShortcut, _ b: SnippetShortcut?) -> Bool {
        guard let b else { return false }
        return a.keyCode == b.keyCode && a.modifiers == b.modifiers
    }

    /// Clashes with devPaste's own shortcuts.
    private func ownShortcutClash(_ shortcut: SnippetShortcut) -> String? {
        if same(shortcut, settings.panelShortcut) { return "Used to open devPaste" }
        if same(shortcut, settings.queueNextShortcut) { return "Used for the paste queue" }
        if same(shortcut, settings.queueBackShortcut) { return "Used for the paste queue" }
        return nil
    }

    /// Clashes with devPaste's shortcuts or another snippet (spec: shortcut conflicts).
    private func conflict(for shortcut: SnippetShortcut, snippetID: String?) -> String? {
        if let own = ownShortcutClash(shortcut) { return "\(shortcut.label) is already \(own.lowercased())." }
        if let other = (try? snippets.shortcuts())?.first(where: { $0.id != snippetID && same(shortcut, $0.shortcut) }) {
            return "\(shortcut.label) is already used by the snippet “\(other.name)”."
        }
        return nil
    }

    /// Used by Settings. Keeps the old shortcut if the new one cannot be registered.
    private func applyPanelShortcut(_ shortcut: SnippetShortcut) -> String? {
        if same(shortcut, settings.queueNextShortcut) || same(shortcut, settings.queueBackShortcut) {
            return "\(shortcut.label) is used for the paste queue."
        }
        if (try? snippets.shortcuts())?.contains(where: { same(shortcut, $0.shortcut) }) == true {
            return "\(shortcut.label) is used by a snippet."
        }
        let old = settings.panelShortcut
        panelHotKey = nil
        if let fresh = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, action: { [weak self] in self?.panel.toggle() }) {
            panelHotKey = fresh
            settings.hotKeyCode = shortcut.keyCode
            settings.hotKeyModifiers = shortcut.modifiers
            settings.hotKeyLabel = shortcut.label
            return nil
        }
        panelHotKey = HotKey(keyCode: old.keyCode, modifiers: old.modifiers, action: { [weak self] in self?.panel.toggle() })
        return "\(shortcut.label) is taken by another app. Try another."
    }

    private func applyQueueShortcut(next: Bool, _ shortcut: SnippetShortcut?) -> String? {
        if let shortcut {
            if same(shortcut, settings.panelShortcut) { return "\(shortcut.label) opens devPaste." }
            if same(shortcut, next ? settings.queueBackShortcut : settings.queueNextShortcut) {
                return "\(shortcut.label) is already the other queue shortcut."
            }
            if (try? snippets.shortcuts())?.contains(where: { same(shortcut, $0.shortcut) }) == true {
                return "\(shortcut.label) is used by a snippet."
            }
        }
        let previous = next ? settings.queueNextShortcut : settings.queueBackShortcut
        if next { queueNextHotKey = nil; settings.queueNextShortcut = shortcut } else { queueBackHotKey = nil; settings.queueBackShortcut = shortcut }
        registerQueueHotKeys()
        let registered = next ? queueNextHotKey != nil : queueBackHotKey != nil
        if shortcut != nil && !registered {
            if next { settings.queueNextShortcut = previous } else { settings.queueBackShortcut = previous }
            registerQueueHotKeys()
            return "\(shortcut?.label ?? "That shortcut") is taken by another app. Try another."
        }
        rebuildSnippetHotKeys()
        return nil
    }

    private func reportHotKeyTaken() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "\(settings.hotKeyLabel) is already in use"
        alert.informativeText = "Another app owns that shortcut. Choose a different one in devPaste Settings, Shortcuts. You can still open devPaste from the menu bar."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { showSettings() }
    }

    // MARK: Export and import

    private func export(_ items: [PanelItem]) {
        guard !items.isEmpty else { return }
        let snippetExports = items.compactMap { item -> Archive.SnippetExport? in
            guard let s = item.snippet else { return nil }
            return Archive.SnippetExport(snippet: s, items: model.content(of: item))
        }
        let clipExports = items.compactMap { item -> Archive.ClipExport? in
            guard let c = item.clip else { return nil }
            return Archive.ClipExport(clip: c, items: model.content(of: item))
        }
        writeArchive(snippets: snippetExports, clips: clipExports,
                     name: items.count == 1 ? "devPaste-\(Self.fileSafe(items[0].title)).json" : "devPaste-export.json")
    }

    private func exportAllSnippets() {
        let all = (try? snippets.list(sort: .name)) ?? []
        guard !all.isEmpty else { Toast.show("There are no snippets to export."); return }
        let exports = all.map { Archive.SnippetExport(snippet: $0, items: (try? snippets.items(id: $0.id)) ?? []) }
        writeArchive(snippets: exports, clips: [], name: "devPaste-snippets-\(Date().formatted(.iso8601.year().month().day())).json")
    }

    private func writeArchive(snippets: [Archive.SnippetExport], clips: [Archive.ClipExport], name: String) {
        panel.forceHide()
        let save = NSSavePanel()
        save.nameFieldStringValue = name
        save.allowedContentTypes = [.json]
        save.message = "The export is not encrypted. Keep it somewhere safe."
        NSApp.activate()
        guard save.runModal() == .OK, let url = save.url else { return }
        do {
            let data = try Archive.build(snippets: snippets, clips: clips)
            try data.write(to: url, options: .atomic)
            Toast.show("Exported \(snippets.count + clips.count) items.")
        } catch {
            Toast.show("Export failed: \(error.localizedDescription)")
        }
    }

    private func importSnippets() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.json]
        open.allowsMultipleSelection = false
        open.message = "Choose a devPaste export file"
        NSApp.activate()
        guard open.runModal() == .OK, let url = open.url else { return }
        do {
            let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Archive.maxFileBytes else { throw Archive.ArchiveError(description: "The file is larger than 1 GB.") }
            let candidates = try Archive.parse(try Data(contentsOf: url))
            guard !candidates.isEmpty else { Toast.show("That file has nothing to import."); return }
            let existing = try snippets.currentContentHashes()
            let duplicates = candidates.filter { existing.contains($0.contentHash) }.count
            let alert = NSAlert()
            alert.messageText = "Import \(candidates.count) snippet\(candidates.count == 1 ? "" : "s")?"
            alert.informativeText = duplicates == 0
                ? "They are added as new snippets. Nothing existing is changed."
                : "\(duplicates) match snippets you already have exactly. Skip them, or keep both copies."
            if duplicates > 0 {
                alert.addButton(withTitle: "Import, skip duplicates")
                alert.addButton(withTitle: "Import all")
            } else {
                alert.addButton(withTitle: "Import")
            }
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            let skipDuplicates: Bool
            switch (duplicates > 0, response) {
            case (true, .alertFirstButtonReturn): skipDuplicates = true
            case (true, .alertSecondButtonReturn), (false, .alertFirstButtonReturn): skipDuplicates = false
            default: return
            }
            var categoryIDs = Dictionary((try snippets.categories()).map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { a, _ in a })
            var imported = 0
            for candidate in candidates where !(skipDuplicates && existing.contains(candidate.contentHash)) {
                var categoryID: String?
                if let name = candidate.category?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                    if let id = categoryIDs[name.lowercased()] { categoryID = id } else {
                        let created = try snippets.addCategory(name: name)
                        categoryIDs[name.lowercased()] = created.id
                        categoryID = created.id
                    }
                }
                try snippets.create(SnippetDraft(name: candidate.name, categoryID: categoryID, tags: candidate.tags,
                                                 favourite: candidate.favourite, items: candidate.items))
                imported += 1
            }
            model.reload()
            Toast.show("Imported \(imported) snippet\(imported == 1 ? "" : "s").")
        } catch {
            let alert = NSAlert()
            alert.messageText = "Nothing was imported"
            alert.informativeText = (error as? Archive.ArchiveError)?.description ?? error.localizedDescription
            alert.runModal()
        }
    }

    private static func fileSafe(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = String(s.prefix(40).unicodeScalars.filter { allowed.contains($0) }).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "item" : cleaned.replacingOccurrences(of: " ", with: "-")
    }

    // MARK: Backup and restore

    private func chooseBackupFolder() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        open.prompt = "Use this folder"
        open.message = "Choose a folder on the NAS. devPaste puts its daily snippet backups in a devPaste folder inside it."
        NSApp.activate()
        guard open.runModal() == .OK, let url = open.url else { return }
        settings.backupFolderPath = url.path
        backup.run { Toast.show($0) }
    }

    private func restoreSnippets() {
        let open = NSOpenPanel()
        open.directoryURL = Self.backupFolder
        open.allowsMultipleSelection = false
        open.message = "Choose a snippets backup (snippets-…sqlite)"
        NSApp.activate()
        guard open.runModal() == .OK, let url = open.url else { return }
        do {
            let incoming = try SnippetStore.inspectBackup(url)
            let current = (try? snippets.count()) ?? 0
            let alert = NSAlert()
            alert.messageText = "Replace your \(current) snippets with the \(incoming) in this backup?"
            alert.informativeText = "devPaste backs up your current snippets first, so this can be undone by restoring that backup."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            // N3: back up before any destructive change.
            try FileManager.default.createDirectory(at: Self.backupFolder, withIntermediateDirectories: true)
            let safety = Self.backupFolder.appendingPathComponent("before-restore-\(Int(Date().timeIntervalSince1970)).sqlite")
            try snippets.backup(to: safety)
            _ = try SnippetStore.inspectBackup(safety)
            try snippets.restore(from: url)
            rebuildSnippetHotKeys()
            model.reload(resetSelection: true)
            Log.store.info("backup.restored count=\(incoming, privacy: .public)")
            Toast.show("Restored \(incoming) snippets. Your previous snippets were saved first.")
        } catch {
            let alert = NSAlert()
            alert.messageText = "Nothing was restored"
            alert.informativeText = (error as? SnippetError)?.description ?? "\(error)"
            alert.runModal()
        }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu = NSMenu()
        statusMenu.delegate = self
        // No permanent menu, so a right-click can open the carousel instead.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusIcon()
    }

    /// Left click: the menu. Right click or Control-click: the carousel (Settings, General).
    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if secondary {
            panel.forceHide()
            carousel.toggle(below: button)
        } else {
            carousel.hide()
            // The standard way to show a status item's menu on demand: attach, click, detach.
            statusItem.menu = statusMenu
            button.performClick(nil)
            statusItem.menu = nil
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button, let model else { return }
        let capturing = model.isCapturing
        let symbol = model.presentation ? "eye.slash" : (capturing ? "doc.on.clipboard" : "pause.circle")
        var description = model.presentation ? "devPaste, presentation mode" : (capturing ? "devPaste, capturing" : "devPaste, capture paused")
        if let progress = queue?.progressText { description += ", \(progress)" }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.title = queue?.shortProgress.map { " \($0)" } ?? ""
        button.imagePosition = .imageLeading
        button.toolTip = description
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(ActionItem("Open devPaste    \(settings.hotKeyLabel)") { [unowned self] in self.panel.show() })
        menu.addItem(.separator())

        if !settings.captureStarted {
            menu.addItem(ActionItem("Start capture") { [unowned self] in self.model.startCapture() })
        } else if let text = model.pauseText {
            menu.addItem(info(text))
            menu.addItem(ActionItem("Resume capture") { [unowned self] in self.model.resume() })
        } else {
            let pause = NSMenuItem(title: "Pause capture", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(ActionItem("For 5 minutes") { [unowned self] in self.model.pause(seconds: 300) })
            sub.addItem(ActionItem("For 15 minutes") { [unowned self] in self.model.pause(seconds: 900) })
            sub.addItem(ActionItem("For 1 hour") { [unowned self] in self.model.pause(seconds: 3600) })
            sub.addItem(ActionItem("Until resumed") { [unowned self] in self.model.pause(seconds: nil) })
            pause.submenu = sub
            menu.addItem(pause)
        }
        let presenting = ActionItem("Presentation mode") { [unowned self] in self.model.setPresentation(!self.model.presentation) }
        presenting.state = model.presentation ? .on : .off
        menu.addItem(presenting)
        if model.locked { menu.addItem(info("Screen locked: capture stopped")) }

        menu.addItem(.separator())
        if let progress = queue.progressText { menu.addItem(info(progress)) }
        let next = ActionItem("Paste next from queue" + (settings.queueNextShortcut.map { "    \($0.label)" } ?? "")) { [unowned self] in self.queueNext() }
        next.isEnabled = queue.next != nil
        menu.addItem(next)
        let back = ActionItem("Resend last queue item" + (settings.queueBackShortcut.map { "    \($0.label)" } ?? "")) { [unowned self] in self.queueBack() }
        back.isEnabled = queue.lastSent != nil
        menu.addItem(back)
        let copyMode = ActionItem("Add every new copy to the queue") { [unowned self] in self.queue.copyMode.toggle() }
        copyMode.state = queue.copyMode ? .on : .off
        menu.addItem(copyMode)
        if queue.isActive { menu.addItem(ActionItem("Clear queue") { [unowned self] in self.queue.clear() }) }

        menu.addItem(.separator())
        let delete = NSMenuItem(title: "Delete history", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(ActionItem("Last 5 minutes") { [unowned self] in self.model.deleteRecent(seconds: 300) })
        sub.addItem(ActionItem("Last hour") { [unowned self] in self.model.deleteRecent(seconds: 3600) })
        sub.addItem(.separator())
        sub.addItem(ActionItem("All history, keep pinned…") { [unowned self] in self.confirmDeleteAll(includePinned: false) })
        sub.addItem(ActionItem("All history, including pinned…") { [unowned self] in self.confirmDeleteAll(includePinned: true) })
        delete.submenu = sub
        menu.addItem(delete)

        menu.addItem(.separator())
        menu.addItem(ActionItem("About devPaste") { [unowned self] in self.showAbout() })
        menu.addItem(ActionItem("Settings…", key: ",") { [unowned self] in self.showSettings() })
        menu.addItem(ActionItem("Quit devPaste", key: "q") { NSApp.terminate(nil) })
    }

    private func info(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func confirmDeleteAll(includePinned: Bool) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = includePinned ? "Delete all history, including pinned items?" : "Delete all history except pinned items?"
        alert.informativeText = "This cannot be undone. Quick Snippets are not affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.deleteAll(includePinned: includePinned) }
    }

    // MARK: System events

    private func observeSystem() {
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [unowned self] _ in
            self.model.locked = true
            self.panel.forceHide()
            self.carousel.hide()
            self.queue.clear() // spec: clear the temporary queue while locked
            self.applyCaptureState()
            Log.capture.info("capture.locked")
        }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [unowned self] _ in
            self.model.locked = false
            self.applyCaptureState()
            Log.capture.info("capture.unlocked")
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [unowned self] _ in
            self.monitor.stop()
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [unowned self] _ in
            self.monitor.start()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [unowned self] _ in
            self.panel.screensChanged()
        }
    }

    private func observeSettings() {
        // @Published fires before the value changes, so read the settings on the next turn.
        settings.$retentionDays.dropFirst().sink { [unowned self] _ in
            DispatchQueue.main.async {
                self.store.retention = self.settings.retentionPolicy
                self.work.async {
                    _ = try? self.store.enforceRetention()
                    DispatchQueue.main.async { self.model.reload() }
                }
            }
        }.store(in: &cancellables)
        settings.$captureStarted.dropFirst().sink { [unowned self] _ in
            DispatchQueue.main.async { self.applyCaptureState() }
        }.store(in: &cancellables)
    }

    // MARK: Windows

    func showSettings() {
        if settingsWindow == nil {
            let actions = SettingsActions(
                applyPanelShortcut: { [unowned self] in self.applyPanelShortcut($0) },
                applyQueueShortcut: { [unowned self] next, shortcut in self.applyQueueShortcut(next: next, shortcut) },
                applySnippetShortcutsEnabled: { [unowned self] on in
                    self.settings.snippetShortcutsEnabled = on
                    self.rebuildSnippetHotKeys()
                },
                clearSnippetShortcut: { [unowned self] id in
                    _ = try? self.snippets.setShortcut(id: id, nil)
                    self.rebuildSnippetHotKeys()
                    self.model.reload()
                },
                backupNow: { [unowned self] in self.backup.run { Toast.show($0) } },
                chooseBackupFolder: { [unowned self] in self.chooseBackupFolder() },
                restoreSnippets: { [unowned self] in self.restoreSnippets() },
                exportAllSnippets: { [unowned self] in self.exportAllSnippets() },
                importSnippets: { [unowned self] in self.importSnippets() },
                deleteAllOCR: { [unowned self] in
                    NSApp.activate()
                    let alert = NSAlert()
                    alert.messageText = "Delete all recognised text?"
                    alert.informativeText = "Images stay. Their text stops being searchable. If recognition is on, it starts again in the background."
                    alert.addButton(withTitle: "Delete")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    _ = try? self.store.deleteAllOCR()
                    self.model.ocrTick += 1
                    self.ocr.kick()
                },
                setOCREnabled: { [unowned self] on in
                    self.settings.ocrEnabled = on
                    self.ocr.enabled = on
                    if on { self.ocr.kick() }
                },
                confirmDeleteAll: { [unowned self] pinned in self.confirmDeleteAll(includePinned: pinned) },
                snippetShortcuts: { [unowned self] in
                    ((try? self.snippets.shortcuts()) ?? []).map { SnippetShortcutEntry(id: $0.id, name: $0.name, shortcut: $0.shortcut) }
                },
                shortcutProblems: { [unowned self] in self.shortcutProblems })
            let view = SettingsView(settings: settings, model: model, theme: theme, historyFolder: Self.historyFolder,
                                    snippetFolder: Self.snippetFolder, actions: actions)
                .modifier(Themed(theme: theme))
            let hosting = NSHostingController(rootView: view)
            // Take only the minimum size from SwiftUI, so the window can be resized freely and
            // does not snap back when a tab changes (UI principle 2: resizable windows).
            hosting.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "devPaste Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            // Restore the saved size and position; centre only the first time.
            if !window.setFrameUsingName("devPasteSettings") {
                window.setContentSize(NSSize(width: 620, height: 560))
                window.center()
            }
            window.setFrameAutosaveName("devPasteSettings")
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showAbout() {
        panel.hide()
        if aboutWindow == nil {
            let view = AboutView(model: model, settings: settings, dataFolder: Self.supportFolder,
                                 done: { [weak self] in self?.aboutWindow?.close() })
                .modifier(Themed(theme: theme))
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "About devPaste"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            aboutWindow = window
        }
        NSApp.activate()
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    private func runOnboarding() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "devPaste keeps a history of what you copy"
        alert.informativeText = """
        History stays on this Mac and is never backed up or sent anywhere. Copies that password managers mark as private are skipped. You can exclude apps, pause, or turn on Presentation mode at any time.

        Open devPaste with \(settings.hotKeyLabel), or from the menu bar. Pasting straight into your app needs Accessibility permission; devPaste asks the first time you paste.
        """
        alert.addButton(withTitle: "Start capture")
        alert.addButton(withTitle: "Not now")
        let response = alert.runModal()
        settings.onboarded = true
        if response == .alertFirstButtonReturn { model.startCapture() }
    }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private var handler: () -> Void = {}

    convenience init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(ActionItem.fire), keyEquivalent: key)
        self.handler = handler
        self.target = self
    }

    @objc private func fire() { handler() }
}
