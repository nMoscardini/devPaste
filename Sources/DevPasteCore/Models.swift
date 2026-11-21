import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Pasteboard type identifiers devPaste keeps (spec: Capture). Anything else is skipped, never converted.
public enum PBType {
    public static let plainText = "public.utf8-plain-text"
    public static let rtf = "public.rtf"
    public static let html = "public.html"
    public static let png = "public.png"
    public static let tiff = "public.tiff"
    public static let pdf = "com.adobe.pdf"
    public static let fileURL = "public.file-url"
    public static let url = "public.url"

    /// Added to every devPaste write so the monitor never re-captures its own pastes.
    public static let internalMarker = "com.nino.devpaste.internal"
    /// nspasteboard.org convention: the app that put the content on the pasteboard.
    public static let nsSource = "org.nspasteboard.source"

    /// devPaste's own types. A bookmark lets a moved file be found again. A file copy is a stored copy
    /// of a file inside a snippet, with its original name alongside.
    public static let bookmark = "com.nino.devpaste.bookmark"
    public static let fileCopy = "com.nino.devpaste.file-copy"
    public static let fileName = "com.nino.devpaste.file-name"

    public static let supported: [String] = [plainText, rtf, html, png, tiff, pdf, fileURL, url]
    public static let imageTypes: [String] = [png, tiff]
    /// Never written to the pasteboard as they are.
    public static let internalTypes: Set<String> = [bookmark, fileCopy, fileName]
    /// Not part of an item's identity: a bookmark can differ between two copies of the same file.
    static let notHashed: Set<String> = [bookmark]
}

public enum ContentKind: String, Sendable, CaseIterable {
    case text, richText, image, link, file, pdf

    public var label: String {
        switch self {
        case .text: "Text"
        case .richText: "Rich text"
        case .image: "Image"
        case .link: "Link"
        case .file: "File"
        case .pdf: "PDF"
        }
    }

    public var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "doc.richtext"
        case .image: "photo"
        case .link: "link"
        case .file: "doc"
        case .pdf: "doc.text"
        }
    }
}

/// The filters in the panel (spec: Search).
public enum KindFilter: String, Sendable, CaseIterable, Identifiable {
    case all, text, images, links, files

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .images: "Images"
        case .links: "Links"
        case .files: "Files"
        }
    }

    public var kinds: [ContentKind]? {
        switch self {
        case .all: nil
        case .text: [.text, .richText]
        case .images: [.image]
        case .links: [.link]
        case .files: [.file, .pdf]
        }
    }
}

public struct Representation: Sendable, Equatable {
    public let uti: String
    public let data: Data

    public init(uti: String, data: Data) {
        self.uti = uti
        self.data = data
    }
}

/// One item of a pasteboard transaction, with every supported representation of it.
public struct CapturedItem: Sendable, Equatable {
    public let representations: [Representation]

    public init(representations: [Representation]) {
        self.representations = representations
    }

    public func data(_ uti: String) -> Data? {
        representations.first { $0.uti == uti }?.data
    }

    public var plainText: String? {
        data(PBType.plainText).flatMap { String(data: $0, encoding: .utf8) }
    }

    public var fileURL: URL? {
        data(PBType.fileURL)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public var hasImage: Bool { PBType.imageTypes.contains { data($0) != nil } }

    public var storedFileName: String? {
        data(PBType.fileName).flatMap { String(data: $0, encoding: .utf8) }
    }

    public var hasStoredFile: Bool { data(PBType.fileCopy) != nil }

    /// The representations that may go on the pasteboard unchanged.
    public var pasteableRepresentations: [Representation] {
        representations.filter { !PBType.internalTypes.contains($0.uti) }
    }

    /// The same item with devPaste's internal types removed (for export and for stored text edits).
    public var withoutBookmark: CapturedItem {
        CapturedItem(representations: representations.filter { $0.uti != PBType.bookmark })
    }
}

/// A complete pasteboard transaction, ready to store. Derived fields are worked out once, here.
public struct CapturedTransaction: Sendable {
    public let items: [CapturedItem]
    public let sourceBundleID: String?
    public let sourceName: String?
    public let capturedAt: Date

    public let byteSize: Int
    public let contentHash: String
    public let kind: ContentKind
    public let plainText: String
    public let title: String
    public let excerpt: String
    public let searchBody: String

    public init(items: [CapturedItem], sourceBundleID: String?, sourceName: String?, capturedAt: Date = Date()) {
        self.items = items
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.capturedAt = capturedAt

        byteSize = items.reduce(0) { total, item in total + item.representations.reduce(0) { $0 + $1.data.count } }
        contentHash = ContentHash.of(items)

        let text = items.compactMap(\.plainText).joined(separator: "\n")
        plainText = text
        let files = items.compactMap(\.fileURL)
        let storedNames = items.compactMap { $0.hasStoredFile ? ($0.storedFileName ?? "File") : nil }
        let kind = Self.deriveKind(items: items, text: text, files: files)
        self.kind = kind

        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""

        switch kind {
        case .file:
            title = (files.map(\.lastPathComponent) + storedNames).joined(separator: ", ")
        case .image:
            title = firstLine.isEmpty ? "Image" : String(firstLine.prefix(200))
        case .pdf:
            title = firstLine.isEmpty ? "PDF document" : String(firstLine.prefix(200))
        case .link:
            title = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        case .text, .richText:
            title = firstLine.isEmpty ? "Blank text" : String(firstLine.prefix(200))
        }

        excerpt = String(text.prefix(400))

        // What search sees: the text, file names and paths, the source app. Capped so a huge paste
        // cannot bloat the index; the payload itself is kept whole.
        var body = String(text.prefix(1_000_000))
        if !files.isEmpty {
            body += "\n" + files.map { "\($0.lastPathComponent) \($0.path)" }.joined(separator: "\n")
        }
        if !storedNames.isEmpty { body += "\n" + storedNames.joined(separator: "\n") }
        searchBody = body.precomposedStringWithCompatibilityMapping
    }

    static func deriveKind(items: [CapturedItem], text: String, files: [URL]) -> ContentKind {
        if !files.isEmpty || items.contains(where: { $0.hasStoredFile }) { return .file }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImage = items.contains { $0.hasImage }
        let hasPDF = items.contains { $0.data(PBType.pdf) != nil }
        if trimmed.isEmpty {
            if hasImage { return .image }
            if hasPDF { return .pdf }
        }
        if items.contains(where: { $0.data(PBType.url) != nil }) || isSingleURL(trimmed) { return .link }
        if items.contains(where: { $0.data(PBType.rtf) != nil || $0.data(PBType.html) != nil }) { return .richText }
        if trimmed.isEmpty && hasImage { return .image }
        return .text
    }

    static func isSingleURL(_ s: String) -> Bool {
        guard !s.isEmpty, !s.contains(where: { $0.isWhitespace }), s.count < 4000,
              let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto", "ftp"].contains(scheme)
    }
}

/// What the panel list shows for one stored transaction.
public struct ClipSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let capturedAt: Date
    public let lastCopiedAt: Date
    public let sourceBundleID: String?
    public let sourceName: String?
    public let kind: ContentKind
    public let title: String
    public let excerpt: String
    public let itemCount: Int
    public let byteSize: Int
    public let pinned: Bool
    public let copyCount: Int

    public var linkHost: String? {
        guard kind == .link else { return nil }
        return URL(string: title)?.host
    }
}

/// An app that appears as a source in history, for the filter menu.
public struct SourceApp: Identifiable, Hashable, Sendable {
    public let bundleID: String
    public let name: String
    public var id: String { bundleID }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

enum ContentHash {
    static func of(_ items: [CapturedItem]) -> String {
        #if canImport(CryptoKit)
        var hasher = SHA256()
        for item in items {
            hasher.update(data: Data("item|".utf8))
            for rep in item.representations where !PBType.notHashed.contains(rep.uti) {
                hasher.update(data: Data("\(rep.uti)|\(rep.data.count)|".utf8))
                hasher.update(data: rep.data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        // FNV-1a 64-bit fallback, only used off Apple platforms.
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ d: Data) { for b in d { h ^= UInt64(b); h = h &* 0x100000001b3 } }
        for item in items {
            mix(Data("item|".utf8))
            for rep in item.representations where !PBType.notHashed.contains(rep.uti) { mix(Data("\(rep.uti)|\(rep.data.count)|".utf8)); mix(rep.data) }
        }
        return String(h, radix: 16)
        #endif
    }

    /// SHA-256 of one payload, hex. Used to check exported attachments.
    static func sha256(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return of([CapturedItem(representations: [Representation(uti: "x", data: data)])])
        #endif
    }
}
