import AppKit
import DevPasteCore

/// The main path, end to end, without the UI: real pasteboard read, policy, store, search.
/// Uses a private named pasteboard and a temporary store, so it is safe to run any time.
enum Smoke {
    static func run() -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print((ok ? "PASS " : "FAIL ") + name)
            if !ok { failures += 1 }
        }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("devPaste-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let pb = NSPasteboard(name: NSPasteboard.Name("com.nino.devPaste.smoke"))
        defer { pb.releaseGlobally() }

        do {
            let store = try HistoryStore(directory: folder)
            check(true, "store opens with FTS5")

            // Text plus a PNG, as one item.
            pb.clearContents()
            let item = NSPasteboardItem()
            item.setString("devPaste smoke alpha beta", forType: .string)
            item.setData(samplePNG(), forType: .png)
            pb.writeObjects([item])

            guard case .ok(let tx) = PasteboardMonitor.snapshot(pb, sourceBundleID: "com.apple.TextEdit", sourceName: "TextEdit",
                                                               maxBytes: RetentionPolicy.maxTransactionBytes) else {
                check(false, "snapshot reads the pasteboard")
                return 1
            }
            check(tx.items.count == 1, "one item captured")
            check(tx.items[0].data(PBType.png) != nil, "PNG representation kept")
            check(tx.items[0].plainText == "devPaste smoke alpha beta", "text representation kept")

            let first = try store.commit(tx)
            if case .inserted = first { check(true, "commit inserts") } else { check(false, "commit inserts") }
            let again = try store.commit(tx)
            if case .coalesced = again { check(true, "repeat coalesces") } else { check(false, "repeat coalesces") }

            check(try store.search(SearchRequest(query: "alph")).count == 1, "prefix search finds it")
            check(try store.search(SearchRequest(query: "\"alpha beta\"")).count == 1, "phrase search finds it")
            check(try store.search(SearchRequest(query: "textedit")).count == 1, "source app search finds it")

            if let id = try store.search(SearchRequest()).first?.id {
                let back = try store.items(id: id)
                check(back == tx.items, "content round-trips unchanged")
            } else {
                check(false, "content round-trips unchanged")
            }

            // Privacy: a concealed copy and an excluded app are refused before any payload is read.
            pb.clearContents()
            let secret = NSPasteboardItem()
            secret.setString("not for history", forType: .string)
            secret.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            pb.writeObjects([secret])
            let types = (pb.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) }
            let policy = CapturePolicy(excludedBundleIDs: Set(CapturePolicy.defaultExcludedApps))
            check(policy.decide(types: types, candidateSources: []) == .skipDoNotKeep, "concealed copy skipped")
            check(policy.decide(types: [PBType.plainText], candidateSources: ["com.bitwarden.desktop"]) != .capture, "excluded app skipped")
            check(policy.decide(types: [PBType.plainText, PBType.internalMarker], candidateSources: []) == .skipOwnWrite, "own write skipped")

            try store.delete(ids: try store.search(SearchRequest()).map(\.id))
            check(try store.stats().count == 0, "delete empties history")

            // Snippets: create, search, revise, back up and check the backup opens.
            let snippets = try SnippetStore(directory: folder.appendingPathComponent("snippets"))
            let sid = try snippets.create(SnippetDraft(name: "Smoke signature", tags: ["smoke"], items: tx.items))
            check(try snippets.list(query: "signature").first?.id == sid, "snippet search finds it")
            try snippets.update(id: sid, with: SnippetDraft(name: "Smoke signature", items: [CapturedItem(representations: [
                Representation(uti: PBType.plainText, data: Data("revised".utf8))])]))
            check(try snippets.revisions(id: sid).count == 2, "editing keeps a revision")
            let backupFile = folder.appendingPathComponent("snippets-backup.sqlite")
            try snippets.backup(to: backupFile)
            check(try SnippetStore.inspectBackup(backupFile) == 1, "snippet backup opens and holds the snippet")
            let archive = try Archive.build(snippets: [.init(snippet: try snippets.snippet(id: sid)!, items: try snippets.items(id: sid))], clips: [])
            check(try Archive.parse(archive).count == 1, "export round-trips")
            check(TextTransform.joinPDFLines.apply("a wrap-\nped line") == "a wrapped line", "PDF line join")
        } catch {
            check(false, "no errors (\(error))")
        }

        print(failures == 0 ? "SMOKE OK" : "SMOKE FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    private static func samplePNG() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        return rep?.representation(using: .png, properties: [:]) ?? Data()
    }
}
