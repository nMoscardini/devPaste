import XCTest
@testable import DevPasteCore

final class SnippetStoreTests: XCTestCase {
    private var dir: URL!
    private var store: SnippetStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("devPasteSnippets-\(UUID().uuidString)")
        store = try SnippetStore(directory: dir)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func text(_ s: String) -> [CapturedItem] {
        [CapturedItem(representations: [Representation(uti: PBType.plainText, data: Data(s.utf8))])]
    }

    func testCreateRequiresNameAndContent() {
        XCTAssertThrowsError(try store.create(SnippetDraft(name: "  ", items: text("x"))))
        XCTAssertThrowsError(try store.create(SnippetDraft(name: "Empty", items: [])))
    }

    func testSearchRanksExactNameThenPrefixThenContent() throws {
        try store.create(SnippetDraft(name: "Signature", items: text("Kind regards")))
        try store.create(SnippetDraft(name: "Address", items: text("sig line inside")))
        try store.create(SnippetDraft(name: "Sig", items: text("short")))
        XCTAssertEqual(try store.list(query: "sig").map(\.name), ["Sig", "Signature", "Address"])
    }

    func testTagsAreSearchableAndCleaned() throws {
        let id = try store.create(SnippetDraft(name: "Reply", tags: ["work", " Work ", "", "email"], items: text("Thanks")))
        XCTAssertEqual(try store.snippet(id: id)?.tags, ["email", "work"])
        XCTAssertEqual(try store.list(query: "email").count, 1)
    }

    func testEditingContentKeepsTenRevisions() throws {
        let id = try store.create(SnippetDraft(name: "Draft", items: text("v1")))
        for n in 2...13 {
            XCTAssertTrue(try store.update(id: id, with: SnippetDraft(name: "Draft", items: text("v\(n)"))))
        }
        let revisions = try store.revisions(id: id)
        XCTAssertEqual(revisions.count, SnippetStore.maxRevisions)
        XCTAssertEqual(revisions.first?.number, 13)
        XCTAssertEqual(try store.items(id: id).first?.plainText, "v13")
    }

    func testRenameOnlyMakesNoRevision() throws {
        let id = try store.create(SnippetDraft(name: "A", items: text("same")))
        XCTAssertFalse(try store.update(id: id, with: SnippetDraft(name: "B", items: text("same"))))
        XCTAssertEqual(try store.snippet(id: id)?.name, "B")
        XCTAssertEqual(try store.revisions(id: id).count, 1)
    }

    func testRestoreMakesOldContentNewest() throws {
        let id = try store.create(SnippetDraft(name: "A", items: text("first")))
        try store.update(id: id, with: SnippetDraft(name: "A", items: text("second")))
        try store.restore(id: id, revision: 1)
        XCTAssertEqual(try store.items(id: id).first?.plainText, "first")
        XCTAssertEqual(try store.revisions(id: id).count, 3)
    }

    func testDeletingCategoryKeepsSnippets() throws {
        let category = try store.addCategory(name: "Email")
        let id = try store.create(SnippetDraft(name: "Sig", categoryID: category.id, items: text("x")))
        XCTAssertEqual(try store.list(scope: .category(category.id)).count, 1)
        try store.deleteCategory(id: category.id)
        XCTAssertNil(try store.snippet(id: id)?.categoryID)
        XCTAssertEqual(try store.list(scope: .uncategorised).count, 1)
    }

    func testFavouritesFirstAndMove() throws {
        let a = try store.create(SnippetDraft(name: "A", items: text("a")))
        let b = try store.create(SnippetDraft(name: "B", items: text("b")))
        _ = try store.create(SnippetDraft(name: "C", items: text("c")))
        XCTAssertEqual(try store.list().map(\.name), ["A", "B", "C"])
        try store.move(id: b, by: -1)
        XCTAssertEqual(try store.list().map(\.name), ["B", "A", "C"])
        try store.setFavourite(id: a, true)
        XCTAssertEqual(try store.list().first?.name, "A")
    }

    func testShortcutsAndUse() throws {
        let id = try store.create(SnippetDraft(name: "Sig", items: text("x")))
        try store.setShortcut(id: id, SnippetShortcut(keyCode: 1, modifiers: 2, label: "⌃⌥S"))
        XCTAssertEqual(try store.shortcuts().first?.shortcut.label, "⌃⌥S")
        try store.noteUsed(id: id)
        XCTAssertEqual(try store.snippet(id: id)?.useCount, 1)
        try store.setShortcut(id: id, nil)
        XCTAssertTrue(try store.shortcuts().isEmpty)
    }

    func testDeleteRemovesSearchRow() throws {
        let id = try store.create(SnippetDraft(name: "Gone", items: text("findable")))
        try store.delete(id: id)
        XCTAssertTrue(try store.list(query: "findable").isEmpty)
    }

    func testBackupAndRestore() throws {
        try store.create(SnippetDraft(name: "Keep me", items: text("x")))
        let backup = dir.appendingPathComponent("backup.sqlite")
        try store.backup(to: backup)
        XCTAssertEqual(try SnippetStore.inspectBackup(backup), 1)
        try store.create(SnippetDraft(name: "Added later", items: text("y")))
        try store.restore(from: backup)
        XCTAssertEqual(try store.list().map(\.name), ["Keep me"])
    }

    func testRestoreRejectsOtherFiles() throws {
        let junk = dir.appendingPathComponent("junk.sqlite")
        try Data("not a database".utf8).write(to: junk)
        XCTAssertThrowsError(try store.restore(from: junk))
    }
}

final class ArchiveTests: XCTestCase {
    func testRoundTripStripsBookmarks() throws {
        let item = CapturedItem(representations: [
            Representation(uti: PBType.plainText, data: Data("hello".utf8)),
            Representation(uti: PBType.bookmark, data: Data([1, 2, 3])),
        ])
        let snippet = Snippet(id: "1", name: "Hello", categoryID: nil, categoryName: "Email", tags: ["a"], favourite: true,
                              manualOrder: 1, shortcut: nil, kind: .text, revision: 1, createdAt: Date(), updatedAt: Date(),
                              useCount: 0, excerpt: "hello")
        let data = try Archive.build(snippets: [.init(snippet: snippet, items: [item])], clips: [])
        let back = try Archive.parse(data)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].name, "Hello")
        XCTAssertEqual(back[0].category, "Email")
        XCTAssertEqual(back[0].items[0].representations.map(\.uti), [PBType.plainText])
    }

    func testTamperedChecksumIsRejected() throws {
        let item = CapturedItem(representations: [Representation(uti: PBType.plainText, data: Data("hello".utf8))])
        let snippet = Snippet(id: "1", name: "H", categoryID: nil, categoryName: nil, tags: [], favourite: false,
                              manualOrder: 1, shortcut: nil, kind: .text, revision: 1, createdAt: Date(), updatedAt: Date(),
                              useCount: 0, excerpt: "")
        var json = String(data: try Archive.build(snippets: [.init(snippet: snippet, items: [item])], clips: []), encoding: .utf8)!
        json = json.replacingOccurrences(of: Data("hello".utf8).base64EncodedString(), with: Data("hellO".utf8).base64EncodedString())
        XCTAssertThrowsError(try Archive.parse(Data(json.utf8)))
    }

    func testRejectsNonArchivesAndFutureSchemas() {
        XCTAssertThrowsError(try Archive.parse(Data("{}".utf8)))
        let future = #"{"format":"devPaste-export","schema":99,"exportedAt":"2026-11-20T10:00:00Z","snippets":[]}"#
        XCTAssertThrowsError(try Archive.parse(Data(future.utf8)))
    }
}

final class TextToolsTests: XCTestCase {
    func testTransforms() {
        XCTAssertEqual(TextTransform.upperCase.apply("straße"), "STRASSE")
        XCTAssertEqual(TextTransform.lowerCase.apply("ÉCOLE"), "école")
        XCTAssertEqual(TextTransform.titleCase.apply("hello world"), "Hello World")
        XCTAssertEqual(TextTransform.trim.apply("  x \n"), "x")
        XCTAssertEqual(TextTransform.removeEmptyLines.apply("a\n\n  \nb"), "a\nb")
        XCTAssertEqual(TextTransform.normaliseLineEndings.apply("a\r\nb\rc"), "a\nb\nc")
        XCTAssertEqual(TextTransform.joinPDFLines.apply("This is a hyph-\nenated line\nthat wraps.\n\nNew para."),
                       "This is a hyphenated line that wraps.\n\nNew para.")
    }

    func testCombine() {
        XCTAssertEqual(CombineSeparator.combine(["a", "b"], separator: .comma), "a, b")
        XCTAssertEqual(CombineSeparator.combine(["a", "b"], separator: .blankLine), "a\n\nb")
        XCTAssertEqual(CombineSeparator.combine(["a", "b"], separator: .custom, custom: " | "), "a | b")
    }

    func testBookmarkDoesNotChangeIdentity() {
        let plain = CapturedTransaction(items: [CapturedItem(representations: [Representation(uti: PBType.fileURL, data: Data("file:///a".utf8))])],
                                        sourceBundleID: nil, sourceName: nil)
        let marked = CapturedTransaction(items: [CapturedItem(representations: [Representation(uti: PBType.fileURL, data: Data("file:///a".utf8)),
                                                                                 Representation(uti: PBType.bookmark, data: Data([9]))])],
                                         sourceBundleID: nil, sourceName: nil)
        XCTAssertEqual(plain.contentHash, marked.contentHash)
    }
}

final class OCRDataTests: XCTestCase {
    func testOCRTextIsSearchableAndRemovable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("devPasteOCR-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        let tx = CapturedTransaction(items: [CapturedItem(representations: [Representation(uti: PBType.png, data: Data([1, 2, 3]))])],
                                     sourceBundleID: nil, sourceName: "Preview")
        guard case .inserted(let id) = try store.commit(tx) else { return XCTFail("insert") }
        XCTAssertEqual(try store.pendingOCR(limit: 10), [id])
        try store.setOCR(id: id, state: .ready, text: "Invoice total 42")
        XCTAssertEqual(try store.ocr(id: id).state, .ready)
        XCTAssertEqual(try store.search(SearchRequest(query: "invoice")).count, 1)
        XCTAssertEqual(try store.search(SearchRequest(query: "preview")).count, 1, "source still searchable")
        XCTAssertTrue(try store.pendingOCR(limit: 10).isEmpty)
        try store.deleteAllOCR()
        XCTAssertEqual(try store.search(SearchRequest(query: "invoice")).count, 0)
        XCTAssertEqual(try store.ocr(id: id).state, .pending)
    }
}
