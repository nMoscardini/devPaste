import Foundation

public enum CommitResult: Equatable, Sendable {
    case inserted(String)
    case coalesced(String)
    case tooLarge(Int)
    case storageFull
    case empty
}

public struct RetentionPolicy: Equatable, Sendable {
    /// nil means "until removed" (still subject to the count and size caps).
    public var maxAge: TimeInterval?
    public var maxCount: Int
    public var maxBytes: Int64

    public init(maxAge: TimeInterval?, maxCount: Int = 10_000, maxBytes: Int64 = 1_073_741_824) {
        self.maxAge = maxAge
        self.maxCount = maxCount
        self.maxBytes = maxBytes
    }

    public static let standard = RetentionPolicy(maxAge: 30 * 86_400)
    /// One captured transaction may hold at most 50 MB.
    public static let maxTransactionBytes = 50 * 1024 * 1024
}

public struct RetentionResult: Equatable, Sendable {
    public let deleted: Int
    /// Pinned items alone exceed the size cap. New payloads are refused until Nino cleans up.
    public let fullOfPinned: Bool
}

public enum OCRState: String, Sendable {
    case pending, ready, none, failed

    public var label: String {
        switch self {
        case .pending: "Pending"
        case .ready: "Ready"
        case .none: "No text found"
        case .failed: "Failed"
        }
    }
}

public struct OCRResult: Equatable, Sendable {
    public let state: OCRState
    public let text: String?
}

public struct SearchRequest: Sendable {
    public var query: String
    public var filter: KindFilter
    public var sourceBundleID: String?
    public var since: Date?
    public var limit: Int

    public init(query: String = "", filter: KindFilter = .all, sourceBundleID: String? = nil, since: Date? = nil, limit: Int = 500) {
        self.query = query
        self.filter = filter
        self.sourceBundleID = sourceBundleID
        self.since = since
        self.limit = limit
    }
}

public struct StoreStats: Equatable, Sendable {
    public let count: Int
    public let bytes: Int64
    public let pinnedCount: Int
    public let pinnedBytes: Int64

    public init(count: Int, bytes: Int64, pinnedCount: Int, pinnedBytes: Int64) {
        self.count = count
        self.bytes = bytes
        self.pinnedCount = pinnedCount
        self.pinnedBytes = pinnedBytes
    }
}

/// Clipboard history: one SQLite file with FTS5 search, plus blob files for large payloads.
/// History is temporary by design: the folder is kept out of backups by the app (spec 4, Data).
/// Every call is serialised on one queue, so this is the single writer the spec asks for.
public final class HistoryStore: @unchecked Sendable {
    public static let schemaVersion: Int64 = 2
    /// Payloads larger than this live in blob files rather than inside the database.
    static let inlineLimit = 256 * 1024

    public let directory: URL
    let blobDirectory: URL
    private let db: SQLiteDB
    private let queue = DispatchQueue(label: "com.nino.devPaste.history")
    private var _retention: RetentionPolicy

    public var retention: RetentionPolicy {
        get { queue.sync { _retention } }
        set { queue.sync { _retention = newValue } }
    }

    public init(directory: URL, retention: RetentionPolicy = .standard) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let blobs = directory.appendingPathComponent("blobs", isDirectory: true)
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.directory = directory
        self.blobDirectory = blobs
        self._retention = retention
        self.db = try SQLiteDB(path: directory.appendingPathComponent("history.sqlite").path)
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")
        try migrate()
    }

    // MARK: Schema

    private func migrate() throws {
        let current = try db.scalarInt("PRAGMA user_version")
        if current == Self.schemaVersion { return }
        if current > Self.schemaVersion {
            throw SQLiteError(code: -1, message: "history.sqlite has schema \(current), newer than this app (\(Self.schemaVersion)). Not opened.")
        }
        if current > 0 {
            // N3: back up before any migration. Future schema changes go below this line.
            let backup = directory.appendingPathComponent("history-before-v\(Self.schemaVersion)-\(Int(Date().timeIntervalSince1970)).sqlite")
            try db.exec("VACUUM INTO '\(backup.path.replacingOccurrences(of: "'", with: "''"))'")
        }
        try db.transaction {
            if current < 1 {
                try db.exec("""
                CREATE TABLE clip(
                    seq INTEGER PRIMARY KEY,
                    id TEXT NOT NULL UNIQUE,
                    captured_at REAL NOT NULL,
                    last_copied_at REAL NOT NULL,
                    source_bundle_id TEXT,
                    source_name TEXT,
                    content_hash TEXT NOT NULL,
                    item_count INTEGER NOT NULL,
                    byte_size INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    title TEXT NOT NULL,
                    excerpt TEXT NOT NULL,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    copy_count INTEGER NOT NULL DEFAULT 1,
                    paste_count INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX clip_last ON clip(last_copied_at DESC);
                CREATE INDEX clip_hash ON clip(content_hash);
                CREATE TABLE rep(
                    id INTEGER PRIMARY KEY,
                    clip_seq INTEGER NOT NULL REFERENCES clip(seq) ON DELETE CASCADE,
                    item_ordinal INTEGER NOT NULL,
                    uti TEXT NOT NULL,
                    byte_count INTEGER NOT NULL,
                    data BLOB,
                    blob_name TEXT
                );
                CREATE INDEX rep_clip ON rep(clip_seq);
                CREATE VIRTUAL TABLE clip_fts USING fts5(body, source, tokenize = 'unicode61 remove_diacritics 2');
                CREATE TRIGGER clip_after_delete AFTER DELETE ON clip BEGIN
                    DELETE FROM clip_fts WHERE rowid = old.seq;
                END;
                """)
            }
            if current < 2 {
                // Derived data (OCR text). Rebuildable from the stored image, so kept apart from the source.
                try db.exec("""
                CREATE TABLE derived(
                    clip_seq INTEGER PRIMARY KEY REFERENCES clip(seq) ON DELETE CASCADE,
                    ocr_state TEXT NOT NULL,
                    ocr_text TEXT,
                    version INTEGER NOT NULL DEFAULT 1
                );
                """)
            }
            try db.exec("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    // MARK: Capture

    public func commit(_ tx: CapturedTransaction, keepDuplicates: Bool = false) throws -> CommitResult {
        try queue.sync {
            guard !tx.items.isEmpty else { return .empty }
            if tx.byteSize > RetentionPolicy.maxTransactionBytes { return .tooLarge(tx.byteSize) }

            let at = tx.capturedAt.timeIntervalSince1970
            if !keepDuplicates, let existing = try idForHashUnlocked(tx.contentHash) {
                try db.run("""
                    UPDATE clip SET last_copied_at = ?, copy_count = copy_count + 1,
                        source_bundle_id = COALESCE(?, source_bundle_id), source_name = COALESCE(?, source_name)
                    WHERE id = ?
                    """, [.double(at), opt(tx.sourceBundleID), opt(tx.sourceName), .text(existing)])
                return .coalesced(existing)
            }

            let pinnedBytes = try db.scalarInt("SELECT COALESCE(SUM(byte_size), 0) FROM clip WHERE pinned = 1")
            if pinnedBytes + Int64(tx.byteSize) > _retention.maxBytes { return .storageFull }

            let id = UUID().uuidString
            var written: [URL] = []
            do {
                // Large payloads go to files first; the database rows that point at them are one transaction.
                var rows: [(ordinal: Int, uti: String, count: Int, data: Data?, blob: String?)] = []
                for (ordinal, item) in tx.items.enumerated() {
                    for rep in item.representations {
                        if rep.data.count > Self.inlineLimit {
                            let name = UUID().uuidString
                            let url = blobDirectory.appendingPathComponent(name)
                            try rep.data.write(to: url, options: .atomic)
                            written.append(url)
                            rows.append((ordinal: ordinal, uti: rep.uti, count: rep.data.count, data: nil, blob: name))
                        } else {
                            rows.append((ordinal: ordinal, uti: rep.uti, count: rep.data.count, data: rep.data, blob: nil))
                        }
                    }
                }
                try db.transaction {
                    try db.run("""
                        INSERT INTO clip(id, captured_at, last_copied_at, source_bundle_id, source_name, content_hash,
                                         item_count, byte_size, kind, title, excerpt)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?)
                        """, [.text(id), .double(at), .double(at), opt(tx.sourceBundleID), opt(tx.sourceName),
                              .text(tx.contentHash), .int(Int64(tx.items.count)), .int(Int64(tx.byteSize)),
                              .text(tx.kind.rawValue), .text(tx.title), .text(tx.excerpt)])
                    let seq = db.lastInsertRowID
                    for r in rows {
                        try db.run("INSERT INTO rep(clip_seq, item_ordinal, uti, byte_count, data, blob_name) VALUES (?,?,?,?,?,?)",
                                   [.int(seq), .int(Int64(r.ordinal)), .text(r.uti), .int(Int64(r.count)),
                                    r.data.map { SQLValue.blob($0) } ?? SQLValue.null, opt(r.blob)])
                    }
                    try db.run("INSERT INTO clip_fts(rowid, body, source) VALUES (?,?,?)",
                               [.int(seq), .text(tx.searchBody), .text(tx.sourceName ?? "")])
                }
            } catch {
                for url in written { try? FileManager.default.removeItem(at: url) }
                throw error
            }
            return .inserted(id)
        }
    }

    // MARK: Read

    public func search(_ request: SearchRequest) throws -> [ClipSummary] {
        try queue.sync {
            var sql = """
                SELECT clip.id, clip.captured_at, clip.last_copied_at, clip.source_bundle_id, clip.source_name, clip.kind,
                       clip.title, clip.excerpt, clip.item_count, clip.byte_size, clip.pinned, clip.copy_count
                FROM clip
                """
            var conditions: [String] = []
            var args: [SQLValue] = []
            if let match = SearchQuery.ftsExpression(request.query) {
                sql += " JOIN clip_fts ON clip_fts.rowid = clip.seq"
                conditions.append("clip_fts MATCH ?")
                args.append(.text(match))
            }
            if let kinds = request.filter.kinds {
                conditions.append("clip.kind IN (" + kinds.map { _ in "?" }.joined(separator: ",") + ")")
                args += kinds.map { SQLValue.text($0.rawValue) }
            }
            if let source = request.sourceBundleID {
                conditions.append("clip.source_bundle_id = ?")
                args.append(.text(source))
            }
            if let since = request.since {
                conditions.append("clip.last_copied_at >= ?")
                args.append(.double(since.timeIntervalSince1970))
            }
            if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
            sql += " ORDER BY clip.last_copied_at DESC LIMIT ?"
            args.append(.int(Int64(request.limit)))

            var results: [ClipSummary] = []
            try db.query(sql, args) { row in
                results.append(ClipSummary(
                    id: row.text(0) ?? "",
                    capturedAt: Date(timeIntervalSince1970: row.double(1)),
                    lastCopiedAt: Date(timeIntervalSince1970: row.double(2)),
                    sourceBundleID: row.text(3),
                    sourceName: row.text(4),
                    kind: ContentKind(rawValue: row.text(5) ?? "") ?? .text,
                    title: row.text(6) ?? "",
                    excerpt: row.text(7) ?? "",
                    itemCount: Int(row.int(8)),
                    byteSize: Int(row.int(9)),
                    pinned: row.int(10) != 0,
                    copyCount: Int(row.int(11))))
            }
            return results
        }
    }

    /// The full stored content of one transaction, item by item. Missing blob files are skipped.
    public func items(id: String) throws -> [CapturedItem] {
        try queue.sync {
            var grouped: [Int: [Representation]] = [:]
            try db.query("""
                SELECT rep.item_ordinal, rep.uti, rep.data, rep.blob_name FROM rep
                JOIN clip ON clip.seq = rep.clip_seq WHERE clip.id = ? ORDER BY rep.item_ordinal, rep.id
                """, [.text(id)]) { row in
                let ordinal = Int(row.int(0))
                let uti = row.text(1) ?? ""
                var data = row.blob(2)
                if data == nil, let name = row.text(3) {
                    data = try? Data(contentsOf: blobDirectory.appendingPathComponent(name))
                }
                if let data { grouped[ordinal, default: []].append(Representation(uti: uti, data: data)) }
            }
            return grouped.keys.sorted().map { CapturedItem(representations: grouped[$0] ?? []) }
        }
    }

    /// The first payload of the given types, in order of preference. Used for thumbnails and previews.
    public func firstPayload(id: String, utis: [String]) throws -> Data? {
        for uti in utis {
            let found: Data? = try queue.sync {
                var result: Data?
                try db.query("""
                    SELECT rep.data, rep.blob_name FROM rep JOIN clip ON clip.seq = rep.clip_seq
                    WHERE clip.id = ? AND rep.uti = ? ORDER BY rep.item_ordinal LIMIT 1
                    """, [.text(id), .text(uti)]) { row in
                    if let d = row.blob(0) { result = d }
                    else if let name = row.text(1) { result = try? Data(contentsOf: blobDirectory.appendingPathComponent(name)) }
                }
                return result
            }
            if let found { return found }
        }
        return nil
    }

    public func formats(id: String) throws -> [String] {
        try queue.sync {
            var utis: [String] = []
            try db.query("SELECT DISTINCT rep.uti FROM rep JOIN clip ON clip.seq = rep.clip_seq WHERE clip.id = ?", [.text(id)]) {
                if let u = $0.text(0) { utis.append(u) }
            }
            return utis
        }
    }

    /// Source apps seen in history, for the filter menu.
    public func sources() throws -> [SourceApp] {
        try queue.sync {
            var out: [SourceApp] = []
            try db.query("""
                SELECT source_bundle_id, MAX(COALESCE(source_name, source_bundle_id)) FROM clip
                WHERE source_bundle_id IS NOT NULL GROUP BY source_bundle_id ORDER BY 2 COLLATE NOCASE
                """) { row in
                if let id = row.text(0) { out.append(SourceApp(bundleID: id, name: row.text(1) ?? id)) }
            }
            return out
        }
    }

    public func stats() throws -> StoreStats {
        try queue.sync {
            var s = StoreStats(count: 0, bytes: 0, pinnedCount: 0, pinnedBytes: 0)
            try db.query("""
                SELECT COUNT(*), COALESCE(SUM(byte_size),0),
                       COALESCE(SUM(pinned),0), COALESCE(SUM(CASE WHEN pinned = 1 THEN byte_size ELSE 0 END),0)
                FROM clip
                """) { row in
                s = StoreStats(count: Int(row.int(0)), bytes: row.int(1), pinnedCount: Int(row.int(2)), pinnedBytes: row.int(3))
            }
            return s
        }
    }

    // MARK: Change

    public func setPinned(id: String, pinned: Bool) throws {
        try queue.sync { _ = try db.run("UPDATE clip SET pinned = ? WHERE id = ?", [.int(pinned ? 1 : 0), .text(id)]) }
    }

    public func notePasteRequested(id: String) throws {
        try queue.sync { _ = try db.run("UPDATE clip SET paste_count = paste_count + 1 WHERE id = ?", [.text(id)]) }
    }

    @discardableResult
    public func delete(ids: [String]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try queue.sync {
            try deleteUnlocked(where: "id IN (" + ids.map { _ in "?" }.joined(separator: ",") + ")", ids.map { SQLValue.text($0) })
        }
    }

    /// Delete everything copied since `date` (last 5 minutes, last hour). Pinned items included: the user asked.
    @discardableResult
    public func deleteCopied(since date: Date) throws -> Int {
        try queue.sync { try deleteUnlocked(where: "last_copied_at >= ?", [.double(date.timeIntervalSince1970)]) }
    }

    @discardableResult
    public func deleteAll(includePinned: Bool) throws -> Int {
        try queue.sync { try deleteUnlocked(where: includePinned ? "1 = 1" : "pinned = 0", []) }
    }

    /// Apply age, count and size limits. Oldest unpinned items go first. Pinned items are never removed here.
    @discardableResult
    public func enforceRetention(now: Date = Date()) throws -> RetentionResult {
        try queue.sync {
            let policy = _retention
            var deleted = 0
            if let maxAge = policy.maxAge {
                deleted += try deleteUnlocked(where: "pinned = 0 AND last_copied_at < ?", [.double(now.timeIntervalSince1970 - maxAge)])
            }
            let count = try db.scalarInt("SELECT COUNT(*) FROM clip")
            if count > Int64(policy.maxCount) {
                deleted += try deleteUnlocked(
                    where: "seq IN (SELECT seq FROM clip WHERE pinned = 0 ORDER BY last_copied_at ASC LIMIT ?)",
                    [.int(count - Int64(policy.maxCount))])
            }
            var fullOfPinned = false
            while try db.scalarInt("SELECT COALESCE(SUM(byte_size),0) FROM clip") > policy.maxBytes {
                let n = try deleteUnlocked(
                    where: "seq IN (SELECT seq FROM clip WHERE pinned = 0 ORDER BY last_copied_at ASC LIMIT 25)", [])
                if n == 0 { fullOfPinned = true; break }
                deleted += n
            }
            return RetentionResult(deleted: deleted, fullOfPinned: fullOfPinned)
        }
    }

    /// Remove blob files no row points at, older than an hour (the recovery grace period).
    @discardableResult
    public func collectOrphanBlobs(now: Date = Date()) throws -> Int {
        try queue.sync {
            var referenced = Set<String>()
            try db.query("SELECT blob_name FROM rep WHERE blob_name IS NOT NULL") { if let n = $0.text(0) { referenced.insert(n) } }
            let fm = FileManager.default
            let files = try fm.contentsOfDirectory(at: blobDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
            var removed = 0
            for url in files where !referenced.contains(url.lastPathComponent) {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
                if now.timeIntervalSince(modified) > 3600 {
                    try? fm.removeItem(at: url)
                    removed += 1
                }
            }
            return removed
        }
    }

    // MARK: OCR (derived data)

    /// Image clips with no OCR result yet, newest first.
    public func pendingOCR(limit: Int) throws -> [String] {
        try queue.sync {
            var ids: [String] = []
            try db.query("""
                SELECT clip.id FROM clip LEFT JOIN derived ON derived.clip_seq = clip.seq
                WHERE clip.kind = 'image' AND derived.clip_seq IS NULL
                ORDER BY clip.last_copied_at DESC LIMIT ?
                """, [.int(Int64(limit))]) { if let id = $0.text(0) { ids.append(id) } }
            return ids
        }
    }

    public func ocr(id: String) throws -> OCRResult {
        try queue.sync {
            var result = OCRResult(state: .pending, text: nil)
            try db.query("""
                SELECT derived.ocr_state, derived.ocr_text FROM derived JOIN clip ON clip.seq = derived.clip_seq WHERE clip.id = ?
                """, [.text(id)]) { row in
                result = OCRResult(state: OCRState(rawValue: row.text(0) ?? "") ?? .failed, text: row.text(1))
            }
            return result
        }
    }

    /// Stores an OCR result and makes the recognised text searchable. The image is untouched.
    public func setOCR(id: String, state: OCRState, text: String?) throws {
        try queue.sync {
            guard let seq = try seqUnlocked(id: id) else { return } // deleted while OCR ran
            try db.transaction {
                try db.run("INSERT OR REPLACE INTO derived(clip_seq, ocr_state, ocr_text, version) VALUES (?,?,?,1)",
                           [.int(seq), .text(state.rawValue), text.map { SQLValue.text($0) } ?? SQLValue.null])
                try setOCRSearchTextUnlocked(seq: seq, text: state == .ready ? text : nil)
            }
        }
    }

    /// Forget one result so the worker tries again.
    public func retryOCR(id: String) throws {
        try queue.sync {
            guard let seq = try seqUnlocked(id: id) else { return }
            try db.transaction {
                try db.run("DELETE FROM derived WHERE clip_seq = ?", [.int(seq)])
                try setOCRSearchTextUnlocked(seq: seq, text: nil)
            }
        }
    }

    /// Delete all OCR text and its search entries (spec: turning OCR off offers this).
    public func deleteAllOCR() throws {
        try queue.sync {
            var seqs: [Int64] = []
            try db.query("SELECT clip_seq FROM derived WHERE ocr_state = 'ready'") { seqs.append($0.int(0)) }
            try db.transaction {
                for seq in seqs { try setOCRSearchTextUnlocked(seq: seq, text: nil) }
                try db.run("DELETE FROM derived")
            }
        }
    }

    private static let ocrMarker = "\n\u{1F}\u{1E}\u{1F}\n"

    private func setOCRSearchTextUnlocked(seq: Int64, text: String?) throws {
        var body = ""
        try db.query("SELECT body FROM clip_fts WHERE rowid = ?", [.int(seq)]) { body = $0.text(0) ?? "" }
        if let range = body.range(of: Self.ocrMarker) { body = String(body[..<range.lowerBound]) }
        if let text, !text.isEmpty { body += Self.ocrMarker + text.precomposedStringWithCompatibilityMapping }
        try db.run("UPDATE clip_fts SET body = ? WHERE rowid = ?", [.text(body), .int(seq)])
    }

    private func seqUnlocked(id: String) throws -> Int64? {
        var seq: Int64?
        try db.query("SELECT seq FROM clip WHERE id = ?", [.text(id)]) { seq = $0.int(0) }
        return seq
    }

    // MARK: Private (call only inside queue.sync)

    private func idForHashUnlocked(_ hash: String) throws -> String? {
        var id: String?
        try db.query("SELECT id FROM clip WHERE content_hash = ? ORDER BY last_copied_at DESC LIMIT 1", [.text(hash)]) { id = $0.text(0) }
        return id
    }

    /// Deletes matching clips, their representations (cascade), search rows (trigger) and blob files.
    private func deleteUnlocked(where condition: String, _ args: [SQLValue]) throws -> Int {
        var blobs: [String] = []
        try db.query("SELECT blob_name FROM rep WHERE blob_name IS NOT NULL AND clip_seq IN (SELECT seq FROM clip WHERE \(condition))", args) {
            if let n = $0.text(0) { blobs.append(n) }
        }
        let changed = try db.transaction { try db.run("DELETE FROM clip WHERE \(condition)", args) }
        for name in blobs { try? FileManager.default.removeItem(at: blobDirectory.appendingPathComponent(name)) }
        return changed
    }

    private func opt(_ s: String?) -> SQLValue { s.map { SQLValue.text($0) } ?? SQLValue.null }
}
