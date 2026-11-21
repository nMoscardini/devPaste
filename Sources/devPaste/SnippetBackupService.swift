import Foundation
import DevPasteCore

/// Daily snippet backup (spec 4, Data; N4). Writes a consistent copy to local disk first (H2),
/// checks it opens, keeps the last 14, then copies it to the NAS folder chosen in Settings.
final class SnippetBackupService {
    static let keep = 14
    private let store: SnippetStore
    private let settings: AppSettings
    let localFolder: URL
    private let work = DispatchQueue(label: "com.nino.devPaste.backup", qos: .utility)

    init(store: SnippetStore, settings: AppSettings, localFolder: URL) {
        self.store = store
        self.settings = settings
        self.localFolder = localFolder
    }

    /// Runs if the last backup is more than 20 hours old.
    func runIfDue() {
        if let last = settings.lastBackupAt, Date().timeIntervalSince(last) < 20 * 3600 { return }
        run()
    }

    func run(completion: ((String) -> Void)? = nil) {
        let nasPath = settings.backupFolderPath
        work.async {
            let (message, success) = self.perform(nasPath: nasPath)
            DispatchQueue.main.async {
                self.settings.lastBackupMessage = message
                if success { self.settings.lastBackupAt = Date() }
                Log.store.info("backup.done ok=\(success, privacy: .public)")
                completion?(message)
            }
        }
    }

    private func perform(nasPath: String?) -> (String, Bool) {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "snippets-\(formatter.string(from: Date())).sqlite"
        let local = localFolder.appendingPathComponent(name)
        let count: Int
        do {
            try fm.createDirectory(at: localFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try store.backup(to: local)
            count = try SnippetStore.inspectBackup(local)
        } catch {
            try? fm.removeItem(at: local)
            return ("Backup failed: \(error). Nothing was changed.", false)
        }
        Self.prune(localFolder)
        let time = Date().formatted(date: .abbreviated, time: .shortened)
        let what = count == 1 ? "1 snippet" : "\(count) snippets"

        guard let nasPath, !nasPath.isEmpty else {
            return ("Backed up \(what) on this Mac at \(time). No NAS folder chosen.", true)
        }
        let nas = URL(fileURLWithPath: nasPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: nas.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ("Backed up \(what) on this Mac at \(time). The NAS folder was not reachable, so it was not copied there.", true)
        }
        let target = nas.appendingPathComponent("devPaste", isDirectory: true)
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let dest = target.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: local, to: dest)
            Self.prune(target)
        } catch {
            return ("Backed up \(what) on this Mac at \(time). Copy to the NAS failed: \(error.localizedDescription)", true)
        }
        return ("Backed up \(what) at \(time), on this Mac and the NAS.", true)
    }

    /// Keep the newest 14 backups in a folder. Names sort by time.
    static func prune(_ folder: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        let backups = files.filter { $0.hasPrefix("snippets-") && $0.hasSuffix(".sqlite") }.sorted()
        for old in backups.dropLast(keep) {
            try? fm.removeItem(at: folder.appendingPathComponent(old))
        }
    }

    func backups() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: localFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("snippets-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
