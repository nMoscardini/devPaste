import SwiftUI
import DevPasteCore

/// One history row: thumbnail or type icon, title or two lines of text, source app and time.
struct ClipRow: View {
    let clip: ClipSummary
    let number: Int?
    let selected: Bool
    let store: HistoryStore
    var hideThumbnail = false
    /// "Clipboard" when both views are searched together.
    var viewLabel: String? = nil
    @Environment(\.areaAccent) private var accent
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RowThumbnail(clip: clip, store: store, hide: hideThumbnail)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayText)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            VStack(alignment: .trailing, spacing: 4) {
                if let number {
                    Text("⌘\(number)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                if clip.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .rowChrome(selected: selected, accent: accent, contrast: contrast)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
    }

    private var displayText: String {
        switch clip.kind {
        case .text, .richText:
            let trimmed = clip.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? clip.title : trimmed
        default:
            return clip.title
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let viewLabel { parts.append(viewLabel) }
        if let host = clip.linkHost { parts.append(host) }
        parts.append(clip.sourceName ?? "Unknown")
        parts.append(clip.lastCopiedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
        if clip.itemCount > 1 { parts.append("\(clip.itemCount) items") }
        return parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        var s = "\(clip.kind.label), \(clip.title), from \(clip.sourceName ?? "unknown app"), "
        s += clip.lastCopiedAt.formatted(.relative(presentation: .named))
        if clip.pinned { s += ", pinned" }
        if let number { s += ", Command \(number) to paste" }
        return s
    }
}

/// Image thumbnail decoded off the main thread, or the type symbol in an IconTile.
private struct RowThumbnail: View {
    let clip: ClipSummary
    let store: HistoryStore
    let hide: Bool
    @Environment(\.areaAccent) private var accent
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image, !hide {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            } else {
                IconTile(colour: accent, symbol: clip.kind.symbol)
                    .frame(width: 36, height: 36)
            }
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
        .task(id: clip.id) {
            image = nil
            guard clip.kind == .image else { return }
            image = await ImageLoader.thumbnail(store: store, id: clip.id, maxPixel: 96)
        }
    }
}

extension View {
    /// Shared row look: a tinted fill and an outline when selected. The outline means selection is
    /// not shown by colour alone, and it thickens with Increase Contrast.
    func rowChrome(selected: Bool, accent: Color, contrast: ColorSchemeContrast) -> some View {
        self
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? accent.opacity(0.18) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? accent.opacity(contrast == .increased ? 1 : 0.65) : Color.clear,
                              lineWidth: contrast == .increased ? 2 : 1))
            .contentShape(Rectangle())
    }
}

/// One snippet row: type icon, name, category or excerpt, shortcut, favourite.
struct SnippetRow: View {
    let snippet: Snippet
    let number: Int?
    let selected: Bool
    var viewLabel: String? = nil
    @Environment(\.areaAccent) private var accent
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconTile(colour: accent, symbol: snippet.kind.symbol)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(snippet.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            VStack(alignment: .trailing, spacing: 4) {
                if let number {
                    Text("⌘\(number)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    if let shortcut = snippet.shortcut {
                        Text(shortcut.label).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if snippet.favourite {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityHidden(true)
        }
        .rowChrome(selected: selected, accent: accent, contrast: contrast)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
    }

    private var subtitle: String {
        var parts: [String] = []
        if let viewLabel { parts.append(viewLabel) }
        parts.append(snippet.categoryName ?? "Uncategorised")
        let excerpt = snippet.excerpt.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if !excerpt.isEmpty { parts.append(excerpt) } else { parts.append(snippet.kind.label) }
        return parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        var s = "Snippet, \(snippet.name), \(snippet.kind.label), \(snippet.categoryName ?? "uncategorised")"
        if snippet.favourite { s += ", favourite" }
        if let shortcut = snippet.shortcut { s += ", shortcut \(shortcut.label)" }
        if let number { s += ", Command \(number) to paste" }
        return s
    }
}
