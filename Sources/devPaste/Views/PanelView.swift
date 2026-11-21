import SwiftUI
import DevPasteCore

/// The floating panel: segmented control, search, list on the left, preview on the right, footer.
/// Editors and dialogs open as an overlay inside the panel, so focus never leaves it.
struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var queue: PasteQueue
    @FocusState private var searchFocused: Bool
    @AppStorage("listWidth") private var listWidth: Double = 360
    @Environment(\.themeColours) private var colours

    /// Below this width the preview collapses and Space or ⌘Y opens it as an overlay (spec: Panel).
    private let collapseWidth: CGFloat = 760

    var body: some View {
        ZStack {
            AccentWash(accent: model.section.accent, top: PanelWash.top, upper: PanelWash.upper,
                       middle: PanelWash.middle, glow: PanelWash.glow)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                header
                searchBar
                Divider()
                content
                Divider()
                footer
            }
            .disabled(model.modal != nil)
            if let modal = model.modal {
                ModalHost(modal: modal, model: model)
            }
        }
        .environment(\.areaAccent, model.section.accent)
        .tint(model.section.accent)
        .frame(minWidth: 620, minHeight: 400)
        .onReceive(model.$focusTick) { _ in if model.modal == nil { searchFocused = true } }
    }

    // MARK: Header and search

    private var header: some View {
        HStack(spacing: 12) {
            Picker("View", selection: Binding(get: { model.section }, set: { model.switchSection(to: $0) })) {
                ForEach(PanelSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)
            .help("Switch view (Tab)")

            Spacer()

            if model.section == .snippets {
                Button { model.newSnippet() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New snippet (⌘N)")
                    .accessibilityLabel("New snippet")
            }
            Button { model.modal = .queue } label: {
                Image(systemName: queue.isActive ? "list.number" : "list.bullet")
            }
            .buttonStyle(.borderless)
            .help("Paste queue (⌘L)")
            .accessibilityLabel("Paste queue")

            Toggle(isOn: $settings.keepOpen) {
                Image(systemName: settings.keepOpen ? "pin.fill" : "pin")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Keep open")
            .accessibilityLabel("Keep open")

            Button { model.onOpenSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(model.section == .clipboard ? "Search clipboard" : "Search snippets", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .accessibilityLabel("Search")
            if model.hasActiveFilters {
                Button("Clear") { model.clearFilters() }
                    .buttonStyle(SoftCapsule(quiet: true))
                    .accessibilityLabel("Clear search and filters")
            }
            Toggle(isOn: $model.searchBoth) { Text("Both") }
                .toggleStyle(.button)
                .help("Search both views (⌘B)")
                .accessibilityLabel("Search both Clipboard and Quick Snippets")
            if model.section == .clipboard { clipFilterMenu } else { snippetFilterMenu }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var clipFilterMenu: some View {
        Menu {
            Picker("Type", selection: $model.filter) {
                ForEach(KindFilter.allCases) { Text($0.label).tag($0) }
            }
            Picker("When", selection: $model.dateFilter) {
                ForEach(DateFilter.allCases) { Text($0.label).tag($0) }
            }
            Picker("App", selection: $model.sourceFilter) {
                Text("Any app").tag(String?.none)
                ForEach(model.sources) { source in
                    Text(source.name).tag(String?.some(source.bundleID))
                }
            }
        } label: {
            Label(clipFilterLabel, systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Filters, \(clipFilterLabel)")
    }

    private var clipFilterLabel: String {
        var parts: [String] = []
        if model.filter != .all { parts.append(model.filter.label) }
        if model.dateFilter != .any { parts.append(model.dateFilter.label) }
        if let id = model.sourceFilter { parts.append(model.sources.first { $0.bundleID == id }?.name ?? "App") }
        return parts.isEmpty ? "All" : parts.joined(separator: ", ")
    }

    private var snippetFilterMenu: some View {
        Menu {
            Picker("Show", selection: $model.snippetScope) {
                Text("All").tag(SnippetScope.all)
                Text("Favourites").tag(SnippetScope.favourites)
                Text("Uncategorised").tag(SnippetScope.uncategorised)
                ForEach(model.categories) { category in
                    Text(category.name).tag(SnippetScope.category(category.id))
                }
            }
            Picker("Sort", selection: Binding(get: { settings.snippetSort },
                                             set: { settings.snippetSort = $0; model.reload() })) {
                ForEach(SnippetSort.allCases) { Text($0.label).tag($0) }
            }
            Divider()
            Button("New category…") { model.newCategory() }
            if case .category(let id) = model.snippetScope, let category = model.categories.first(where: { $0.id == id }) {
                Button("Rename “\(category.name)”…") { model.renameCategory(category) }
                Button("Delete “\(category.name)”…") { model.deleteCategory(category) }
            }
        } label: {
            Label(model.scopeLabel, systemImage: "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Show, \(model.scopeLabel)")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let error = model.loadError {
            EmptyState(symbol: "exclamationmark.triangle", title: "Data could not be read", detail: error)
        } else if model.section == .clipboard && !settings.captureStarted && model.stats.count == 0 && model.items.isEmpty {
            EmptyState(symbol: "pause.circle", title: "Capture is off",
                       detail: "devPaste only keeps what you copy after you start capture. History stays on this Mac.") {
                Button("Start capture") { model.startCapture() }.buttonStyle(PrimaryCapsule())
            }
        } else if model.section == .clipboard && model.stats.count == 0 && model.items.isEmpty {
            EmptyState(symbol: "doc.on.clipboard", title: "Copy something to start",
                       detail: "Anything you copy appears here. Password managers that mark their copies are skipped.")
        } else if model.section == .snippets && model.snippetCount == 0 && model.items.isEmpty {
            EmptyState(symbol: PanelSection.snippets.symbol, title: "No snippets yet",
                       detail: "Save text you reuse. Select something in Clipboard and press ⌘S, or make a new one.") {
                Button("New snippet") { model.newSnippet() }.buttonStyle(PrimaryCapsule())
            }
        } else if model.items.isEmpty {
            EmptyState(symbol: "magnifyingglass", title: "No matches",
                       detail: "Nothing matches \(model.query.isEmpty ? "these filters" : "“\(model.query)”").") {
                Button("Clear filters") { model.clearFilters() }.buttonStyle(SoftCapsule())
            }
        } else {
            GeometryReader { geo in
                if geo.size.width < collapseWidth {
                    list
                        .overlay {
                            if model.previewOverlay, let item = model.focused {
                                ItemPreview(item: item, model: model)
                                    .background(colours.card)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .shadow(radius: 12)
                                    .padding(16)
                            }
                        }
                } else {
                    HStack(spacing: 0) {
                        list.frame(width: clampedListWidth(total: geo.size.width))
                        divider(total: geo.size.width)
                        if let item = model.focused {
                            ItemPreview(item: item, model: model)
                        } else {
                            Color.clear
                        }
                    }
                }
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        row(item, number: index < 9 ? index + 1 : nil)
                            .id(item.id)
                            .onTapGesture(count: 2) { model.select(item.id); model.paste(item) }
                            .onTapGesture {
                                let flags = NSEvent.modifierFlags
                                model.click(item, command: flags.contains(.command), shift: flags.contains(.shift))
                            }
                            .contextMenu { RowMenu(item: item, model: model) }
                            .accessibilityAction(named: "Paste") { model.paste(item) }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .accessibilityLabel(model.section == .clipboard ? "Clipboard history" : "Quick Snippets")
    }

    @ViewBuilder
    private func row(_ item: PanelItem, number: Int?) -> some View {
        let selected = model.isSelected(item)
        let label = model.searchBoth && !model.query.isEmpty
        switch item {
        case .clip(let clip):
            ClipRow(clip: clip, number: number, selected: selected, store: model.store,
                    hideThumbnail: model.presentation, viewLabel: label ? "Clipboard" : nil)
                .environment(\.areaAccent, PanelSection.clipboard.accent)
        case .snippet(let snippet):
            SnippetRow(snippet: snippet, number: number, selected: selected, viewLabel: label ? "Snippet" : nil)
                .environment(\.areaAccent, PanelSection.snippets.accent)
        }
    }

    private func clampedListWidth(total: CGFloat) -> CGFloat {
        min(max(CGFloat(listWidth), 260), total - 320)
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                let proposed = clampedListWidth(total: total) + value.translation.width
                listWidth = Double(min(max(proposed, 260), total - 320))
            })
            .accessibilityHidden(true)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Text(hints)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let progress = queue.progressText {
                Button { model.modal = .queue } label: { Label(progress, systemImage: "list.number") }
                    .buttonStyle(.borderless)
                    .help("Open the paste queue (⌘L)")
            }
            if model.presentation {
                Label("Presentation mode", systemImage: "eye.slash")
            } else if model.locked {
                Label("Screen locked", systemImage: "lock.fill").foregroundStyle(.secondary)
            } else if let text = model.pauseText {
                Label(text, systemImage: "pause.circle.fill")
                Button("Resume") { model.resume() }.buttonStyle(SoftCapsule(quiet: true))
            } else if !settings.captureStarted {
                Label("Capture off", systemImage: "pause.circle")
            }
            if model.fullOfPinned {
                Label("Storage full", systemImage: "externaldrive.badge.exclamationmark")
                    .help("Pinned items fill the 1 GB limit. Unpin or delete some.")
            }
            Text(countText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var hints: String {
        if model.selection.count > 1 {
            return "\(model.selection.count) selected   ↩ Combine   ⌘J Add to queue   ⌘⌫ Delete"
        }
        return model.section == .clipboard
            ? "↩ Paste   ⌥↩ Plain   ⌘S Save as snippet   ⌘E Edit   ⇧↑↓ Select more   Tab Snippets"
            : "↩ Paste   ⌥↩ Plain   ⌘E Edit   ⌘N New   ⌘D Duplicate   ⌥⌘↑↓ Reorder   Tab Clipboard"
    }

    private var countText: String {
        let n = model.section == .clipboard ? model.stats.count : model.snippetCount
        let noun = model.section == .clipboard ? "item" : "snippet"
        return n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }
}

/// Right-click menu for a row.
struct RowMenu: View {
    let item: PanelItem
    @ObservedObject var model: AppModel

    var body: some View {
        Button("Paste") { model.paste(item) }
        Button("Paste as plain text") { model.paste(item, plain: true) }
        Button("Copy") { model.copy(item) }
        Divider()
        switch item {
        case .clip(let clip):
            Button("Save to Quick Snippets") { model.saveAsSnippet(item) }
            if item.isTextLike { Button("Edit and transform…") { model.edit(item) } }
            Button(clip.pinned ? "Unpin" : "Pin") { model.togglePinOrFavourite(item) }
        case .snippet(let snippet):
            Button("Edit…") { model.edit(item) }
            Button("Duplicate") { model.duplicate(item) }
            Button(snippet.favourite ? "Remove from favourites" : "Add to favourites") { model.togglePinOrFavourite(item) }
        }
        Button("Add selection to queue") {
            if !model.isSelected(item) { model.select(item.id) }
            model.enqueueSelection()
        }
        Button("Export selection…") {
            if !model.isSelected(item) { model.select(item.id) }
            model.exportSelection()
        }
        Divider()
        Button("Delete", role: .destructive) { model.delete(item) }
    }
}

/// An empty, error or off state: what happened and what to do next (UI_PRINCIPLES section 5).
struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.system(.title2, design: .serif, weight: .semibold))
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            actions()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(symbol: String, title: String, detail: String) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}
