import AppKit
import SwiftUI
import DevPasteCore

/// The right-click carousel: a small panel that drops down under the menu bar icon and shows the
/// last 4 copies, or the first 4 snippets, as pictures. Clicking one copies it, ready for ⌘V.
///
/// Like the main panel it never activates devPaste, so the app you came from stays in front and
/// ⌘V goes straight into it.
final class CarouselController: NSObject, NSWindowDelegate {
    private let panel: DevPanel
    private let model: AppModel
    private let settings: AppSettings
    private let theme: ThemeStore
    private var monitors: [Any] = []
    private var hiddenAt = Date.distantPast
    /// Copies the item. Set by AppController.
    var onCopy: (PanelItem) -> Void = { _ in }

    init(model: AppModel, settings: AppSettings, theme: ThemeStore) {
        self.model = model
        self.settings = settings
        self.theme = theme
        panel = DevPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 230),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.setAccessibilityLabel("devPaste recent items")
    }

    var isVisible: Bool { panel.isVisible }

    func toggle(below button: NSStatusBarButton) {
        if panel.isVisible { hide(); return }
        // The click that closed it (by taking focus) should not open it again straight away.
        if Date().timeIntervalSince(hiddenAt) < 0.25 { return }
        show(below: button)
    }

    func show(below button: NSStatusBarButton) {
        let source = settings.carouselSource
        let items = load(source)
        let view = CarouselView(source: source, items: items, store: model.store, snippets: model.snippets,
                                hidden: model.presentation, copy: { [weak self] item in self?.copy(item) })
            .modifier(Themed(theme: theme, alwaysActive: true, ownsWindow: false))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        position(below: button)
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        removeMonitors()
        hiddenAt = Date()
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    private func copy(_ item: PanelItem) {
        hide()
        onCopy(item)
    }

    private func load(_ source: CarouselSource) -> [PanelItem] {
        switch source {
        case .copies:
            return ((try? model.store.search(SearchRequest(limit: 4))) ?? []).map { .clip($0) }
        case .snippets:
            return ((try? model.snippets.list(sort: settings.snippetSort)) ?? []).prefix(4).map { .snippet($0) }
        }
    }

    /// Centred under the icon, kept inside the screen's visible area.
    private func position(below button: NSStatusBarButton) {
        guard let window = button.window else { return }
        let iconFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        let size = panel.frame.size
        var origin = NSPoint(x: iconFrame.midX - size.width / 2, y: iconFrame.minY - size.height - 6)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = max(origin.y, visible.minY + 8)
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: Closing

    private func installMonitors() {
        removeMonitors()
        // A click anywhere else closes it.
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.hide()
        }) { monitors.append(outside) }
        // Escape closes it. Number keys 1 to 4 are handled by the cards' shortcuts.
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.keyCode == 53 { self.hide(); return nil }
            return event
        }) { monitors.append(keys) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}

// MARK: Views

private struct CarouselView: View {
    let source: CarouselSource
    let items: [PanelItem]
    let store: HistoryStore
    let snippets: SnippetStore
    let hidden: Bool
    let copy: (PanelItem) -> Void

    private var section: PanelSection { source == .copies ? .clipboard : .snippets }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(source == .copies ? "Recent copies" : "Quick Snippets", systemImage: section.symbol)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 16)
                if !items.isEmpty {
                    Text("Click or press 1 to \(items.count) to copy, then ⌘V")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if items.isEmpty {
                Text(source == .copies ? "Nothing copied yet." : "No snippets yet. Make one in devPaste.")
                    .foregroundStyle(.secondary)
                    .frame(width: 300, height: 80)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        CarouselCard(item: item, number: index + 1, store: store, snippets: snippets,
                                     hidden: hidden, copy: { copy(item) })
                    }
                }
            }
            if hidden {
                Label("Presentation mode: contents hidden", systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .environment(\.areaAccent, section.accent)
        .fixedSize()
    }
}

private struct CarouselCard: View {
    let item: PanelItem
    let number: Int
    let store: HistoryStore
    let snippets: SnippetStore
    let hidden: Bool
    let copy: () -> Void
    @Environment(\.areaAccent) private var accent
    @Environment(\.themeColours) private var colours
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var image: NSImage?
    @State private var hovering = false

    private static let width: CGFloat = 150
    private static let height: CGFloat = 112

    var body: some View {
        Button(action: copy) {
            VStack(alignment: .leading, spacing: 6) {
                picture
                    .frame(width: Self.width, height: Self.height)
                    .background(colours.card)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(hovering ? accent : colours.border,
                                      lineWidth: hovering ? (contrast == .increased ? 3 : 2) : 1))
                HStack(spacing: 4) {
                    Text("\(number)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(accent)
                    Text(hidden ? item.kind.label : item.title).font(.caption).lineLimit(1)
                }
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: Self.width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPress())
        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [])
        .onHover { hovering = $0 }
        .help("Copy, then press ⌘V to paste")
        .accessibilityLabel("Copy \(item.kind.label), \(hidden ? "contents hidden" : item.title). Shortcut \(number).")
        .task(id: item.id) { await loadImage() }
    }

    @ViewBuilder
    private var picture: some View {
        if hidden {
            placeholder
        } else if let image {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: Self.width, height: Self.height)
                .clipped()
        } else if [.text, .richText].contains(item.kind), !excerpt.isEmpty {
            Text(excerpt)
                .font(.system(size: 11))
                .lineLimit(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            IconTile(colour: accent, symbol: item.kind.symbol).frame(width: 36, height: 36)
            Text(hidden ? item.kind.label : (item.clip?.linkHost ?? item.kind.label))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(8)
    }

    private var excerpt: String {
        let text = item.clip?.excerpt ?? item.snippet?.excerpt ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var subtitle: String {
        switch item {
        case .clip(let c):
            return [c.sourceName ?? "Unknown", c.lastCopiedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))]
                .joined(separator: " · ")
        case .snippet(let s):
            return s.categoryName ?? (s.favourite ? "Favourite" : "Uncategorised")
        }
    }

    /// Images are decoded off the main thread at card size (spec: Files and images).
    private func loadImage() async {
        image = nil
        guard !hidden, item.kind == .image else { return }
        switch item {
        case .clip(let c):
            image = await ImageLoader.thumbnail(store: store, id: c.id, maxPixel: 320)
        case .snippet(let s):
            let snippets = snippets
            let cg: CGImage? = await Task.detached(priority: .utility) {
                guard let items = try? snippets.items(id: s.id),
                      let data = items.lazy.flatMap(\.representations).first(where: { PBType.imageTypes.contains($0.uti) })?.data
                else { return nil }
                return ImageLoader.downsample(data, maxPixel: 320)
            }.value
            image = cg.map { NSImage(cgImage: $0, size: .zero) }
        }
    }
}
