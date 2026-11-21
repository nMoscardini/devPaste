import Foundation
import DevPasteCore

/// File references (spec: Files and links). A reference is not a backup: devPaste keeps the path and
/// a bookmark, so a moved file can usually be found again, and says Unavailable when it cannot.
enum FileResolver {
    enum Status: Equatable {
        case available(URL)
        case moved(from: URL, to: URL)
        case unavailable(URL)

        var url: URL? {
            switch self {
            case .available(let u): u
            case .moved(_, let u): u
            case .unavailable: nil
            }
        }
    }

    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func status(of item: CapturedItem) -> Status? {
        guard let url = item.fileURL else { return nil }
        if FileManager.default.fileExists(atPath: url.path) { return .available(url) }
        if let data = item.data(PBType.bookmark) {
            var stale = false
            if let found = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                    relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: found.path) {
                return .moved(from: url, to: found)
            }
        }
        return .unavailable(url)
    }

    /// Representations ready for the pasteboard: internal types removed, a moved file's new
    /// location used, a stored file copy written out to a temporary file. Items that cannot be
    /// pasted (a file that is gone) are dropped.
    static func pasteable(_ items: [CapturedItem], scratch: URL) -> [CapturedItem] {
        items.compactMap { item in
            if item.hasStoredFile, let data = item.data(PBType.fileCopy) {
                let name = item.storedFileName ?? "File"
                let folder = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let url = folder.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } catch {
                    Log.paste.error("paste.fileCopyFailed error=\(String(describing: error), privacy: .public)")
                    return nil
                }
                return CapturedItem(representations: [Representation(uti: PBType.fileURL, data: Data(url.absoluteString.utf8))])
            }
            var reps = item.pasteableRepresentations
            if let status = status(of: item) {
                switch status {
                case .available: break
                case .moved(_, let to):
                    reps = reps.map { $0.uti == PBType.fileURL ? Representation(uti: PBType.fileURL, data: Data(to.absoluteString.utf8)) : $0 }
                case .unavailable:
                    return nil
                }
            }
            return reps.isEmpty ? nil : CapturedItem(representations: reps)
        }
    }

    /// Temporary files for stored copies older than a day are removed at launch.
    static func cleanScratch(_ scratch: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: scratch, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in entries {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if Date().timeIntervalSince(modified) > 86_400 { try? fm.removeItem(at: url) }
        }
    }
}
