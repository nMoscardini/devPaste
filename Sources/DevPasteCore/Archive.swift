import Foundation

/// Export and import (spec: Export and import). One JSON file with the attachments inside it,
/// base64 encoded, each with its size and SHA-256 so damage is caught before anything is written.
/// Bookmarks are stripped: they only mean something on this Mac.
public enum Archive {
    public static let format = "devPaste-export"
    public static let schema = 1
    /// Refuse files larger than this before reading them.
    public static let maxFileBytes = 1_073_741_824

    struct File: Codable {
        var format: String
        var schema: Int
        var exportedAt: Date
        var snippets: [Entry]
    }

    struct Entry: Codable {
        var name: String
        var category: String?
        var tags: [String]
        var favourite: Bool
        var origin: String
        var items: [Item]
    }

    struct Item: Codable {
        var representations: [Rep]
    }

    struct Rep: Codable {
        var uti: String
        var size: Int
        var sha256: String
        var data: String
    }

    public struct Candidate: Sendable {
        public let name: String
        public let category: String?
        public let tags: [String]
        public let favourite: Bool
        public let items: [CapturedItem]
        public let contentHash: String
    }

    public struct ArchiveError: Error, CustomStringConvertible {
        public let description: String
        public init(description: String) { self.description = description }
    }

    /// What can be imported: the supported pasteboard types plus devPaste's stored file copies.
    static let importableTypes: Set<String> = Set(PBType.supported).union([PBType.fileCopy, PBType.fileName])

    public struct SnippetExport {
        public let snippet: Snippet
        public let items: [CapturedItem]
        public init(snippet: Snippet, items: [CapturedItem]) { self.snippet = snippet; self.items = items }
    }

    public struct ClipExport {
        public let clip: ClipSummary
        public let items: [CapturedItem]
        public init(clip: ClipSummary, items: [CapturedItem]) { self.clip = clip; self.items = items }
    }

    public static func build(snippets: [SnippetExport], clips: [ClipExport], now: Date = Date()) throws -> Data {
        func entryItems(_ items: [CapturedItem]) -> [Item] {
            items.map { item in
                Item(representations: item.representations
                    .filter { importableTypes.contains($0.uti) }
                    .map { Rep(uti: $0.uti, size: $0.data.count, sha256: ContentHash.sha256($0.data), data: $0.data.base64EncodedString()) })
            }
        }
        var entries = snippets.map {
            Entry(name: $0.snippet.name, category: $0.snippet.categoryName, tags: $0.snippet.tags,
                  favourite: $0.snippet.favourite, origin: "snippet", items: entryItems($0.items))
        }
        entries += clips.map {
            Entry(name: String($0.clip.title.prefix(80)), category: nil, tags: [], favourite: false,
                  origin: "history", items: entryItems($0.items))
        }
        let file = File(format: format, schema: schema, exportedAt: now, snippets: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    /// Validates everything before returning: format, schema, types, sizes and checksums.
    /// Nothing is written here; the caller shows counts and conflicts, then commits.
    public static func parse(_ data: Data) throws -> [Candidate] {
        guard data.count <= maxFileBytes else { throw ArchiveError(description: "The file is larger than 1 GB.") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file: File
        do { file = try decoder.decode(File.self, from: data) } catch {
            throw ArchiveError(description: "This is not a devPaste export file.")
        }
        guard file.format == format else { throw ArchiveError(description: "This is not a devPaste export file.") }
        guard file.schema <= schema else {
            throw ArchiveError(description: "This file comes from a newer devPaste (schema \(file.schema)). Update devPaste first.")
        }
        var out: [Candidate] = []
        for (index, entry) in file.snippets.enumerated() {
            var items: [CapturedItem] = []
            var total = 0
            for item in entry.items {
                var reps: [Representation] = []
                for rep in item.representations {
                    guard importableTypes.contains(rep.uti) else {
                        throw ArchiveError(description: "Entry \(index + 1) has an unsupported type (\(rep.uti)).")
                    }
                    guard rep.size >= 0, rep.size <= RetentionPolicy.maxTransactionBytes,
                          let bytes = Data(base64Encoded: rep.data), bytes.count == rep.size else {
                        throw ArchiveError(description: "Entry \(index + 1) is damaged (size does not match).")
                    }
                    guard ContentHash.sha256(bytes) == rep.sha256.lowercased() else {
                        throw ArchiveError(description: "Entry \(index + 1) is damaged (checksum does not match).")
                    }
                    total += bytes.count
                    reps.append(Representation(uti: rep.uti, data: bytes))
                }
                if !reps.isEmpty { items.append(CapturedItem(representations: reps)) }
            }
            guard total <= RetentionPolicy.maxTransactionBytes else {
                throw ArchiveError(description: "Entry \(index + 1) is larger than 50 MB.")
            }
            guard !items.isEmpty else { continue }
            let tx = CapturedTransaction(items: items, sourceBundleID: nil, sourceName: nil)
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Candidate(name: name.isEmpty ? String(tx.title.prefix(80)) : name,
                                 category: entry.category, tags: entry.tags, favourite: entry.favourite,
                                 items: items, contentHash: tx.contentHash))
        }
        return out
    }
}
