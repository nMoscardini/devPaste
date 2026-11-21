import Foundation

public struct SnippetShortcut: Equatable, Hashable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    public let label: String

    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }
}

public struct SnippetCategory: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let manualOrder: Int
}

public struct Snippet: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let categoryID: String?
    public let categoryName: String?
    public let tags: [String]
    public let favourite: Bool
    public let manualOrder: Int
    public let shortcut: SnippetShortcut?
    public let kind: ContentKind
    public let revision: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let useCount: Int
    public let excerpt: String
}

public struct SnippetRevisionInfo: Identifiable, Equatable, Sendable {
    public var id: Int { number }
    public let number: Int
    public let createdAt: Date
    public let excerpt: String
}

public struct SnippetDraft: Sendable {
    public var name: String
    public var categoryID: String?
    public var tags: [String]
    public var favourite: Bool
    public var items: [CapturedItem]

    public init(name: String, categoryID: String? = nil, tags: [String] = [], favourite: Bool = false, items: [CapturedItem]) {
        self.name = name
        self.categoryID = categoryID
        self.tags = tags
        self.favourite = favourite
        self.items = items
    }

    /// The first text line, or the file name, as the spec suggests.
    public static func suggestedName(for items: [CapturedItem]) -> String {
        let tx = CapturedTransaction(items: items, sourceBundleID: nil, sourceName: nil)
        return String(tx.title.prefix(80))
    }
}

public enum SnippetScope: Hashable, Sendable {
    case all, favourites, uncategorised
    case category(String)
}

public enum SnippetSort: String, CaseIterable, Identifiable, Sendable {
    case favouritesFirst, name, modified, mostUsed

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .favouritesFirst: "Favourites, then my order"
        case .name: "Name"
        case .modified: "Last changed"
        case .mostUsed: "Most used"
        }
    }
}

public struct SnippetError: Error, CustomStringConvertible {
    public let description: String
    public init(description: String) { self.description = description }
}

/// Quick Snippets: permanent, reusable content. Unlike history this IS backed up (spec 4, Data).
/// Everything lives in one SQLite file so a backup is one consistent copy (H2).
public final class SnippetStore: @unchecked Sendable {
    public static let schemaVersion: Int64 = 1
    public static let maxRevisions = 10

    public let directory: URL
    public let databaseURL: URL
    private let db: SQLiteDB
    private let queue = DispatchQueue(label: "com.nino.devPaste.snippets")

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.directory = directory
        self.databaseURL = directory.appendingPathComponent("snippets.sqlite")
        self.db = try SQLiteDB(path: databaseURL.path)
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")
        try migrate()
    }

    private func migrate() throws {
        let current = try db.scalarInt("PRAGMA user_version")
        if current == Self.schemaVersion { return }
        if current > Self.schemaVersion {
            throw SnippetError(description: "snippets.sqlite has schema \(current), newer than this app. Not opened.")
        }
        if current > 0 {
            try db.vacuumInto(directory.appendingPathComponent("snippets-before-v\(Self.schemaVersion)-\(Int(Date().timeIntervalSince1970)).sqlite").path)
        }
        try db.transaction {
            if current < 1 {
                try db.exec("""
                CREATE TABLE category(
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    manual_order INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE snippet(
                    seq INTEGER PRIMARY KEY,
                    id TEXT NOT NULL UNIQUE,
                    name TEXT NOT NULL,
                    category_id TEXT REFERENCES category(id) ON DELETE SET NULL,
                    favourite INTEGER NOT NULL DEFAULT 0,
                    manual_order INTEGER NOT NULL DEFAULT 0,
                    shortcut_code INTEGER,
                    shortcut_mods INTEGER,
                    shortcut_label TEXT,
                    kind TEXT NOT NULL,
                    excerpt TEXT NOT NULL,
                    current_revision INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    use_count INTEGER NOT NULL DEFAULT 0,
                    last_used_at REAL
                );
                CREATE TABLE snippet_tag(
                    snippet_seq INTEGER NOT NULL REFERENCES snippet(seq) ON DELETE CASCADE,
                    tag TEXT NOT NULL,
                    PRIMARY KEY(snippet_seq, tag)
                );
                CREATE TABLE revision(
                    id INTEGER PRIMARY KEY,
                    snippet_seq INTEGER NOT NULL REFERENCES snippet(seq) ON DELETE CASCADE,
                    number INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    content_hash TEXT NOT NULL,
                    excerpt TEXT NOT NULL,
                    UNIQUE(snippet_seq, number)
                );
                CREATE TABLE revision_rep(
                    id INTEGER PRIMARY KEY,
                    revision_id INTEGER NOT NULL REFERENCES revision(id) ON DELETE CASCADE,
                    item_ordinal INTEGER NOT NULL,
                    uti TEXT NOT NULL,
                    data BLOB NOT NULL
                );
                CREATE INDEX revision_rep_revision ON revision_rep(revision_id);
                CREATE VIRTUAL TABLE snippet_fts USING fts5(name, tags, body, tokenize = 'unicode61 remove_diacritics 2');
                CREATE TRIGGER snippet_after_delete AFTER DELETE ON snippet BEGIN
                    DELETE FROM snippet_fts WHERE rowid = old.seq;
                END;
                """)
            }
            try db.exec("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    // MARK: Categories

    public func categories() throws -> [SnippetCategory] {
        try queue.sync {
            var out: [SnippetCategory] = []
            try db.query("SELECT id, name, manual_order FROM category ORDER BY manual_order, name COLLATE NOCASE") { row in
                out.append(SnippetCategory(id: row.text(0) ?? "", name: row.text(1) ?? "", manualOrder: Int(row.int(2))))
            }
            return out
        }
    }

    @discardableResult
    public func addCategory(name: String) throws -> SnippetCategory {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SnippetError(description: "A category needs a name.") }
        return try queue.sync {
            let order = Int(try db.scalarInt("SELECT COALESCE(MAX(manual_order), 0) + 1 FROM category"))
            let id = UUID().uuidString
            try db.run("INSERT INTO category(id, name, manual_order) VALUES (?,?,?)", [.text(id), .text(clean), .int(Int64(order))])
            return SnippetCategory(id: id, name: clean, manualOrder: order)
        }
    }

    public func renameCategory(id: String, to name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SnippetError(description: "A category needs a name.") }
        try queue.sync { _ = try db.run("UPDATE category SET name = ? WHERE id = ?", [.text(clean), .text(id)]) }
    }

    /// Deleting a category moves its snippets to Uncategorised. It never deletes snippets.
    public func deleteCategory(id: String) throws {
        try queue.sync {
            try db.transaction {
                try db.run("UPDATE snippet SET category_id = NULL WHERE category_id = ?", [.text(id)])
                try db.run("DELETE FROM category WHERE id = ?", [.text(id)])
            }
        }
    }

    // MARK: Read

    public func list(query: String = "", scope: SnippetScope = .all, sort: SnippetSort = .favouritesFirst) throws -> [Snippet] {
        try queue.sync {
            var sql = """
                SELECT s.seq, s.id, s.name, s.category_id, category.name, s.favourite, s.manual_order,
                       s.shortcut_code, s.shortcut_mods, s.shortcut_label, s.kind, s.current_revision,
                       s.created_at, s.updated_at, s.use_count, s.excerpt
                FROM snippet s LEFT JOIN category ON category.id = s.category_id
                """
            var conditions: [String] = []
            var args: [SQLValue] = []
            let match = SearchQuery.ftsExpression(query)
            if let match {
                sql += " JOIN snippet_fts ON snippet_fts.rowid = s.seq"
                conditions.append("snippet_fts MATCH ?")
                args.append(.text(match))
            }
            switch scope {
            case .all: break
            case .favourites: conditions.append("s.favourite = 1")
            case .uncategorised: conditions.append("s.category_id IS NULL")
            case .category(let id):
                conditions.append("s.category_id = ?")
                args.append(.text(id))
            }
            if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
            if match != nil {
                // Exact name first, then names starting with the query, then content matches.
                let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let like = q.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_") + "%"
                sql += """
                     ORDER BY CASE WHEN lower(s.name) = ? THEN 0 WHEN lower(s.name) LIKE ? ESCAPE '\\' THEN 1 ELSE 2 END,
                              bm25(snippet_fts), s.name COLLATE NOCASE
                    """
                args.append(.text(q))
                args.append(.text(like))
            } else {
                switch sort {
                case .favouritesFirst: sql += " ORDER BY s.favourite DESC, s.manual_order ASC, s.name COLLATE NOCASE"
                case .name: sql += " ORDER BY s.name COLLATE NOCASE"
                case .modified: sql += " ORDER BY s.updated_at DESC"
                case .mostUsed: sql += " ORDER BY s.use_count DESC, s.name COLLATE NOCASE"
                }
            }
            let tags = try tagsBySeqUnlocked()
            var out: [Snippet] = []
            try db.query(sql, args) { row in out.append(snippet(from: row, tags: tags)) }
            return out
        }
    }

    public func snippet(id: String) throws -> Snippet? {
        try queue.sync {
            let tags = try tagsBySeqUnlocked()
            var found: Snippet?
            try db.query("""
                SELECT s.seq, s.id, s.name, s.category_id, category.name, s.favourite, s.manual_order,
                       s.shortcut_code, s.shortcut_mods, s.shortcut_label, s.kind, s.current_revision,
                       s.created_at, s.updated_at, s.use_count, s.excerpt
                FROM snippet s LEFT JOIN category ON category.id = s.category_id WHERE s.id = ?
                """, [.text(id)]) { row in found = snippet(from: row, tags: tags) }
            return found
        }
    }

    /// The content of the current revision, or of an older one.
    public func items(id: String, revision: Int? = nil) throws -> [CapturedItem] {
        try queue.sync {
            var grouped: [Int: [Representation]] = [:]
            let sql = """
                SELECT rr.item_ordinal, rr.uti, rr.data FROM revision_rep rr
                JOIN revision r ON r.id = rr.revision_id
                JOIN snippet s ON s.seq = r.snippet_seq
                WHERE s.id = ? AND r.number = \(revision.map { String($0) } ?? "s.current_revision")
                ORDER BY rr.item_ordinal, rr.id
                """
            try db.query(sql, [.text(id)]) { row in
                grouped[Int(row.int(0)), default: []].append(Representation(uti: row.text(1) ?? "", data: row.blob(2) ?? Data()))
            }
            return grouped.keys.sorted().map { CapturedItem(representations: grouped[$0] ?? []) }
        }
    }

    public func revisions(id: String) throws -> [SnippetRevisionInfo] {
        try queue.sync {
            var out: [SnippetRevisionInfo] = []
            try db.query("""
                SELECT r.number, r.created_at, r.excerpt FROM revision r JOIN snippet s ON s.seq = r.snippet_seq
                WHERE s.id = ? ORDER BY r.number DESC
                """, [.text(id)]) { row in
                out.append(SnippetRevisionInfo(number: Int(row.int(0)), createdAt: Date(timeIntervalSince1970: row.double(1)), excerpt: row.text(2) ?? ""))
            }
            return out
        }
    }

    public func shortcuts() throws -> [(id: String, name: String, shortcut: SnippetShortcut)] {
        try queue.sync {
            var out: [(id: String, name: String, shortcut: SnippetShortcut)] = []
            try db.query("SELECT id, name, shortcut_code, shortcut_mods, shortcut_label FROM snippet WHERE shortcut_code IS NOT NULL ORDER BY name COLLATE NOCASE") { row in
                let shortcut = SnippetShortcut(keyCode: UInt32(row.int(2)), modifiers: UInt32(row.int(3)), label: row.text(4) ?? "")
                out.append((id: row.text(0) ?? "", name: row.text(1) ?? "", shortcut: shortcut))
            }
            return out
        }
    }

    /// Content hashes of every snippet's current revision, for spotting duplicates on import.
    public func currentContentHashes() throws -> Set<String> {
        try queue.sync {
            var out = Set<String>()
            try db.query("SELECT r.content_hash FROM revision r JOIN snippet s ON s.seq = r.snippet_seq AND r.number = s.current_revision") {
                if let h = $0.text(0) { out.insert(h) }
            }
            return out
        }
    }

    public func count() throws -> Int {
        try queue.sync { Int(try db.scalarInt("SELECT COUNT(*) FROM snippet")) }
    }

    // MARK: Change

    @discardableResult
    public func create(_ draft: SnippetDraft) throws -> String {
        let name = try validName(draft.name)
        let tx = try validContent(draft.items)
        return try queue.sync {
            let id = UUID().uuidString
            let now = Date().timeIntervalSince1970
            try db.transaction {
                let order = try db.scalarInt("SELECT COALESCE(MAX(manual_order), 0) + 1 FROM snippet")
                try db.run("""
                    INSERT INTO snippet(id, name, category_id, favourite, manual_order, kind, excerpt, current_revision, created_at, updated_at)
                    VALUES (?,?,?,?,?,?,?,1,?,?)
                    """, [.text(id), .text(name), opt(draft.categoryID), .int(draft.favourite ? 1 : 0), .int(order),
                          .text(tx.kind.rawValue), .text(tx.excerpt), .double(now), .double(now)])
                let seq = db.lastInsertRowID
                try insertRevisionUnlocked(seq: seq, number: 1, tx: tx, at: now)
                try replaceTagsUnlocked(seq: seq, tags: draft.tags)
                try db.run("INSERT INTO snippet_fts(rowid, name, tags, body) VALUES (?,?,?,?)",
                           [.int(seq), .text(name), .text(Self.clean(draft.tags).joined(separator: " ")), .text(tx.searchBody)])
            }
            return id
        }
    }

    /// Saves changes. A change to the content creates a new revision; the last ten are kept.
    /// Returns true when a new revision was made.
    @discardableResult
    public func update(id: String, with draft: SnippetDraft) throws -> Bool {
        let name = try validName(draft.name)
        let tx = try validContent(draft.items)
        return try queue.sync {
            guard let found = try currentRevisionUnlocked(id: id) else {
                throw SnippetError(description: "That snippet no longer exists.")
            }
            let (seq, current, hash) = found
            let now = Date().timeIntervalSince1970
            let changed = hash != tx.contentHash
            try db.transaction {
                try db.run("UPDATE snippet SET name = ?, category_id = ?, favourite = ?, kind = ?, excerpt = ?, updated_at = ? WHERE seq = ?",
                           [.text(name), opt(draft.categoryID), .int(draft.favourite ? 1 : 0), .text(tx.kind.rawValue),
                            .text(tx.excerpt), .double(now), .int(seq)])
                if changed {
                    let next = current + 1
                    try insertRevisionUnlocked(seq: seq, number: next, tx: tx, at: now)
                    try db.run("UPDATE snippet SET current_revision = ? WHERE seq = ?", [.int(Int64(next)), .int(seq)])
                    try db.run("DELETE FROM revision WHERE snippet_seq = ? AND number <= ?",
                               [.int(seq), .int(Int64(next - Self.maxRevisions))])
                }
                try replaceTagsUnlocked(seq: seq, tags: draft.tags)
                try db.run("DELETE FROM snippet_fts WHERE rowid = ?", [.int(seq)])
                try db.run("INSERT INTO snippet_fts(rowid, name, tags, body) VALUES (?,?,?,?)",
                           [.int(seq), .text(name), .text(Self.clean(draft.tags).joined(separator: " ")), .text(tx.searchBody)])
            }
            return changed
        }
    }

    /// Restoring makes the old content the newest revision, so nothing is lost.
    public func restore(id: String, revision: Int) throws {
        guard let s = try snippet(id: id) else { throw SnippetError(description: "That snippet no longer exists.") }
        let old = try items(id: id, revision: revision)
        guard !old.isEmpty else { throw SnippetError(description: "That version is no longer kept.") }
        try update(id: id, with: SnippetDraft(name: s.name, categoryID: s.categoryID, tags: s.tags, favourite: s.favourite, items: old))
    }

    @discardableResult
    public func duplicate(id: String) throws -> String {
        guard let s = try snippet(id: id) else { throw SnippetError(description: "That snippet no longer exists.") }
        return try create(SnippetDraft(name: "\(s.name) copy", categoryID: s.categoryID, tags: s.tags, favourite: false, items: try items(id: id)))
    }

    public func delete(id: String) throws {
        try queue.sync { _ = try db.run("DELETE FROM snippet WHERE id = ?", [.text(id)]) }
    }

    public func setFavourite(id: String, _ favourite: Bool) throws {
        try queue.sync { _ = try db.run("UPDATE snippet SET favourite = ? WHERE id = ?", [.int(favourite ? 1 : 0), .text(id)]) }
    }

    public func setShortcut(id: String, _ shortcut: SnippetShortcut?) throws {
        try queue.sync {
            if let shortcut {
                _ = try db.run("UPDATE snippet SET shortcut_code = ?, shortcut_mods = ?, shortcut_label = ? WHERE id = ?",
                               [.int(Int64(shortcut.keyCode)), .int(Int64(shortcut.modifiers)), .text(shortcut.label), .text(id)])
            } else {
                _ = try db.run("UPDATE snippet SET shortcut_code = NULL, shortcut_mods = NULL, shortcut_label = NULL WHERE id = ?", [.text(id)])
            }
        }
    }

    public func noteUsed(id: String) throws {
        try queue.sync {
            _ = try db.run("UPDATE snippet SET use_count = use_count + 1, last_used_at = ? WHERE id = ?",
                           [.double(Date().timeIntervalSince1970), .text(id)])
        }
    }

    /// Moves a snippet one place up (-1) or down (+1) in the manual order.
    public func move(id: String, by delta: Int) throws {
        try queue.sync {
            var order: [(seq: Int64, id: String)] = []
            try db.query("SELECT seq, id FROM snippet ORDER BY favourite DESC, manual_order ASC, name COLLATE NOCASE") {
                order.append((seq: $0.int(0), id: $0.text(1) ?? ""))
            }
            guard let index = order.firstIndex(where: { $0.id == id }) else { return }
            let target = index + delta
            guard target >= 0, target < order.count else { return }
            order.swapAt(index, target)
            try db.transaction {
                for (position, entry) in order.enumerated() {
                    try db.run("UPDATE snippet SET manual_order = ? WHERE seq = ?", [.int(Int64(position + 1)), .int(entry.seq)])
                }
            }
        }
    }

    // MARK: Backup and restore

    /// A consistent copy of the whole snippet store (H2).
    public func backup(to url: URL) throws {
        try queue.sync { try db.vacuumInto(url.path) }
    }

    /// Checks a backup file opens and holds snippets. Returns how many.
    public static func inspectBackup(_ url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { throw SnippetError(description: "The backup file is missing.") }
        let check = try SQLiteDB(path: url.path)
        let version = try check.scalarInt("PRAGMA user_version")
        guard version >= 1, version <= schemaVersion else {
            throw SnippetError(description: "That file is not a devPaste snippets backup this version can read.")
        }
        var health = ""
        try check.query("PRAGMA quick_check") { health = $0.text(0) ?? "" }
        guard health == "ok" else { throw SnippetError(description: "The backup is damaged.") }
        return Int(try check.scalarInt("SELECT COUNT(*) FROM snippet"))
    }

    /// Replaces every snippet with the contents of a backup. Call `backup(to:)` first (N3).
    public func restore(from url: URL) throws {
        _ = try Self.inspectBackup(url)
        try queue.sync { try db.restore(fromFile: url.path) }
    }

    // MARK: Private (inside queue.sync)

    private func snippet(from row: Row, tags: [Int64: [String]]) -> Snippet {
        let shortcut: SnippetShortcut? = row.isNull(7) ? nil
            : SnippetShortcut(keyCode: UInt32(row.int(7)), modifiers: UInt32(row.int(8)), label: row.text(9) ?? "")
        return Snippet(
            id: row.text(1) ?? "",
            name: row.text(2) ?? "",
            categoryID: row.text(3),
            categoryName: row.text(4),
            tags: tags[row.int(0)] ?? [],
            favourite: row.int(5) != 0,
            manualOrder: Int(row.int(6)),
            shortcut: shortcut,
            kind: ContentKind(rawValue: row.text(10) ?? "") ?? .text,
            revision: Int(row.int(11)),
            createdAt: Date(timeIntervalSince1970: row.double(12)),
            updatedAt: Date(timeIntervalSince1970: row.double(13)),
            useCount: Int(row.int(14)),
            excerpt: row.text(15) ?? "")
    }

    private func tagsBySeqUnlocked() throws -> [Int64: [String]] {
        var out: [Int64: [String]] = [:]
        try db.query("SELECT snippet_seq, tag FROM snippet_tag ORDER BY tag COLLATE NOCASE") { row in
            out[row.int(0), default: []].append(row.text(1) ?? "")
        }
        return out
    }

    private func currentRevisionUnlocked(id: String) throws -> (Int64, Int, String)? {
        var found: (Int64, Int, String)?
        try db.query("""
            SELECT s.seq, s.current_revision, r.content_hash FROM snippet s
            JOIN revision r ON r.snippet_seq = s.seq AND r.number = s.current_revision WHERE s.id = ?
            """, [.text(id)]) { row in found = (row.int(0), Int(row.int(1)), row.text(2) ?? "") }
        return found
    }

    private func insertRevisionUnlocked(seq: Int64, number: Int, tx: CapturedTransaction, at: Double) throws {
        try db.run("INSERT INTO revision(snippet_seq, number, created_at, content_hash, excerpt) VALUES (?,?,?,?,?)",
                   [.int(seq), .int(Int64(number)), .double(at), .text(tx.contentHash), .text(tx.excerpt.isEmpty ? tx.title : tx.excerpt)])
        let revisionID = db.lastInsertRowID
        for (ordinal, item) in tx.items.enumerated() {
            for rep in item.representations {
                try db.run("INSERT INTO revision_rep(revision_id, item_ordinal, uti, data) VALUES (?,?,?,?)",
                           [.int(revisionID), .int(Int64(ordinal)), .text(rep.uti), .blob(rep.data)])
            }
        }
    }

    private func replaceTagsUnlocked(seq: Int64, tags: [String]) throws {
        try db.run("DELETE FROM snippet_tag WHERE snippet_seq = ?", [.int(seq)])
        for tag in Self.clean(tags) {
            try db.run("INSERT OR IGNORE INTO snippet_tag(snippet_seq, tag) VALUES (?,?)", [.int(seq), .text(tag)])
        }
    }

    static func clean(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func validName(_ name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SnippetError(description: "A snippet needs a name.") }
        return clean
    }

    private func validContent(_ items: [CapturedItem]) throws -> CapturedTransaction {
        let nonEmpty = items.filter { !$0.representations.isEmpty }
        guard !nonEmpty.isEmpty else { throw SnippetError(description: "A snippet needs some content.") }
        let tx = CapturedTransaction(items: nonEmpty, sourceBundleID: nil, sourceName: nil)
        guard tx.byteSize <= RetentionPolicy.maxTransactionBytes else {
            throw SnippetError(description: "A snippet can be at most 50 MB.")
        }
        return tx
    }

    private func opt(_ s: String?) -> SQLValue { s.map { SQLValue.text($0) } ?? SQLValue.null }
}
