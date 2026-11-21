import XCTest
@testable import DevPasteCore

final class HistoryStoreTests: XCTestCase {
    private var dir: URL!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("devPasteTests-\(UUID().uuidString)")
        store = try HistoryStore(directory: dir)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func text(_ s: String, source: String? = "com.apple.TextEdit", at: Date = Date()) -> CapturedTransaction {
        CapturedTransaction(items: [CapturedItem(representations: [Representation(uti: PBType.plainText, data: Data(s.utf8))])],
                            sourceBundleID: source, sourceName: source.map { _ in "TextEdit" }, capturedAt: at)
    }

    private func id(_ r: CommitResult) -> String? {
        switch r {
        case .inserted(let id), .coalesced(let id): return id
        default: return nil
        }
    }

    func testCommitAndSearchByPrefixAndPhrase() throws {
        _ = try store.commit(text("devPaste smoke alpha beta"))
        _ = try store.commit(text("something else"))
        XCTAssertEqual(try store.search(SearchRequest(query: "alph")).count, 1)
        XCTAssertEqual(try store.search(SearchRequest(query: "\"alpha beta\"")).count, 1)
        XCTAssertEqual(try store.search(SearchRequest(query: "\"beta alpha\"")).count, 0)
        XCTAssertEqual(try store.search(SearchRequest(query: "ALPHA smoke")).count, 1, "case-insensitive AND")
        XCTAssertEqual(try store.search(SearchRequest(query: "textedit")).count, 2, "source app is searchable")
        XCTAssertEqual(try store.search(SearchRequest()).count, 2)
    }

    func testDuplicateCoalescesAndMovesToTop() throws {
        let first = try store.commit(text("same", at: Date(timeIntervalSince1970: 100)))
        _ = try store.commit(text("other", at: Date(timeIntervalSince1970: 200)))
        let again = try store.commit(text("same", at: Date(timeIntervalSince1970: 300)))
        guard case .inserted(let a) = first, case .coalesced(let b) = again else { return XCTFail("expected insert then coalesce") }
        XCTAssertEqual(a, b)
        let list = try store.search(SearchRequest())
        XCTAssertEqual(list.first?.id, a)
        XCTAssertEqual(list.first?.copyCount, 2)
        XCTAssertEqual(list.count, 2)
    }

    func testKeepDuplicates() throws {
        _ = try store.commit(text("same"), keepDuplicates: true)
        _ = try store.commit(text("same"), keepDuplicates: true)
        XCTAssertEqual(try store.stats().count, 2)
    }

    func testTooLargeIsSkipped() throws {
        let big = Data(count: RetentionPolicy.maxTransactionBytes + 1)
        let tx = CapturedTransaction(items: [CapturedItem(representations: [Representation(uti: PBType.png, data: big)])],
                                     sourceBundleID: nil, sourceName: nil)
        guard case .tooLarge = try store.commit(tx) else { return XCTFail("expected tooLarge") }
        XCTAssertEqual(try store.stats().count, 0)
    }

    func testLargePayloadRoundTripsThroughBlobAndIsDeleted() throws {
        let payload = Data((0..<(HistoryStore.inlineLimit + 10)).map { UInt8($0 % 251) })
        let tx = CapturedTransaction(items: [CapturedItem(representations: [Representation(uti: PBType.png, data: payload)])],
                                     sourceBundleID: nil, sourceName: nil)
        let clipID = try XCTUnwrap(id(try store.commit(tx)))
        XCTAssertEqual(try store.items(id: clipID).first?.data(PBType.png), payload)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.blobDirectory.path).count, 1)
        try store.delete(ids: [clipID])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.blobDirectory.path).count, 0)
    }

    func testDeleteRemovesSearchRows() throws {
        let clipID = try XCTUnwrap(id(try store.commit(text("findable words"))))
        try store.delete(ids: [clipID])
        XCTAssertEqual(try store.search(SearchRequest(query: "findable")).count, 0)
    }

    func testRetentionByAgeKeepsPinned() throws {
        let now = Date()
        let old = try XCTUnwrap(id(try store.commit(text("old", at: now.addingTimeInterval(-40 * 86_400)))))
        let pinned = try XCTUnwrap(id(try store.commit(text("old pinned", at: now.addingTimeInterval(-40 * 86_400)))))
        try store.setPinned(id: pinned, pinned: true)
        _ = try store.commit(text("new", at: now))
        let result = try store.enforceRetention(now: now)
        XCTAssertEqual(result.deleted, 1)
        let ids = try store.search(SearchRequest()).map(\.id)
        XCTAssertFalse(ids.contains(old))
        XCTAssertTrue(ids.contains(pinned))
    }

    func testRetentionByCountEvictsOldestUnpinned() throws {
        store.retention = RetentionPolicy(maxAge: nil, maxCount: 3)
        for i in 0..<5 { _ = try store.commit(text("item \(i)", at: Date(timeIntervalSince1970: Double(100 + i)))) }
        try store.enforceRetention()
        let titles = try store.search(SearchRequest()).map(\.title)
        XCTAssertEqual(titles, ["item 4", "item 3", "item 2"])
    }

    func testPinnedFillingCapacityRefusesNewPayloads() throws {
        store.retention = RetentionPolicy(maxAge: nil, maxCount: 100, maxBytes: 20)
        let a = try XCTUnwrap(id(try store.commit(text("0123456789abcdef"))))
        try store.setPinned(id: a, pinned: true)
        guard case .storageFull = try store.commit(text("more text here")) else { return XCTFail("expected storageFull") }
        XCTAssertTrue(try store.enforceRetention().fullOfPinned == false)
    }

    func testDeleteAllRespectsPinnedChoice() throws {
        let a = try XCTUnwrap(id(try store.commit(text("a"))))
        _ = try store.commit(text("b"))
        try store.setPinned(id: a, pinned: true)
        try store.deleteAll(includePinned: false)
        XCTAssertEqual(try store.stats().count, 1)
        try store.deleteAll(includePinned: true)
        XCTAssertEqual(try store.stats().count, 0)
    }

    func testFilters() throws {
        _ = try store.commit(text("https://example.com/page"))
        _ = try store.commit(text("plain words"))
        XCTAssertEqual(try store.search(SearchRequest(filter: .links)).map(\.kind), [.link])
        XCTAssertEqual(try store.search(SearchRequest(filter: .text)).count, 1)
        XCTAssertEqual(try store.search(SearchRequest(sourceBundleID: "com.apple.TextEdit")).count, 2)
        XCTAssertEqual(try store.search(SearchRequest(sourceBundleID: "com.nothing")).count, 0)
    }

    func testReopenKeepsData() throws {
        _ = try store.commit(text("survives reopen"))
        store = nil
        store = try HistoryStore(directory: dir)
        XCTAssertEqual(try store.search(SearchRequest(query: "survives")).count, 1)
    }
}

final class CaptureModelTests: XCTestCase {
    func testKindDerivation() {
        func kind(_ reps: [Representation]) -> ContentKind {
            CapturedTransaction(items: [CapturedItem(representations: reps)], sourceBundleID: nil, sourceName: nil).kind
        }
        XCTAssertEqual(kind([Representation(uti: PBType.plainText, data: Data("hello".utf8))]), .text)
        XCTAssertEqual(kind([Representation(uti: PBType.plainText, data: Data("https://a.com".utf8))]), .link)
        XCTAssertEqual(kind([Representation(uti: PBType.plainText, data: Data("hi".utf8)),
                             Representation(uti: PBType.rtf, data: Data("{\\rtf1}".utf8))]), .richText)
        XCTAssertEqual(kind([Representation(uti: PBType.png, data: Data([1, 2, 3]))]), .image)
        XCTAssertEqual(kind([Representation(uti: PBType.fileURL, data: Data("file:///tmp/a.txt".utf8))]), .file)
    }

    func testHashDiffersForDifferentRichRepresentations() {
        let plain = CapturedTransaction(items: [CapturedItem(representations: [Representation(uti: PBType.plainText, data: Data("x".utf8))])],
                                        sourceBundleID: nil, sourceName: nil)
        let rich = CapturedTransaction(items: [CapturedItem(representations: [Representation(uti: PBType.plainText, data: Data("x".utf8)),
                                                                               Representation(uti: PBType.html, data: Data("<b>x</b>".utf8))])],
                                       sourceBundleID: nil, sourceName: nil)
        XCTAssertNotEqual(plain.contentHash, rich.contentHash)
    }

    func testPolicy() {
        let policy = CapturePolicy(excludedBundleIDs: ["com.bitwarden.desktop"])
        XCTAssertEqual(policy.decide(types: [PBType.plainText], candidateSources: ["com.apple.TextEdit"]), .capture)
        XCTAssertEqual(policy.decide(types: [PBType.plainText, "org.nspasteboard.ConcealedType"], candidateSources: []), .skipDoNotKeep)
        XCTAssertEqual(policy.decide(types: [PBType.plainText], candidateSources: ["com.apple.TextEdit", "com.bitwarden.desktop"]),
                       .skipExcludedApp("com.bitwarden.desktop"))
        XCTAssertEqual(policy.decide(types: [PBType.plainText, PBType.internalMarker], candidateSources: []), .skipOwnWrite)
        XCTAssertEqual(policy.decide(types: ["com.example.private"], candidateSources: []), .skipNothingSupported)
    }

    func testSearchQuery() {
        XCTAssertNil(SearchQuery.ftsExpression("   "))
        XCTAssertNil(SearchQuery.ftsExpression("- ."))
        XCTAssertEqual(SearchQuery.ftsExpression("alpha beta"), "\"alpha\"* \"beta\"*")
        XCTAssertEqual(SearchQuery.ftsExpression("\"exact phrase\" more"), "\"exact phrase\" \"more\"*")
        XCTAssertEqual(SearchQuery.ftsExpression("\"unclosed phrase"), "\"unclosed phrase\"")
    }
}
