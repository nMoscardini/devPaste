import AppKit
import DevPasteCore

/// Watches the general pasteboard's change count (spec: Capture). macOS has no change
/// notification, so this polls: every 250 ms after recent activity, every 750 ms when idle.
final class PasteboardMonitor {
    enum SnapshotResult {
        case ok(CapturedTransaction)
        case empty
        case unsupported
        case tooLarge(Int)
        /// The pasteboard kept changing while it was being read.
        case unstable
    }

    private let pasteboard: NSPasteboard
    private var lastChangeCount: Int
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var lastChangeAt = Date()

    /// True only when capture is started, not paused and the screen is not locked.
    var isCapturing = false
    var policy: () -> CapturePolicy = { CapturePolicy(excludedBundleIDs: []) }
    var attribution: () -> SourceTracker.Attribution = { .init(candidates: [], bundleID: nil, name: nil) }
    var onTransaction: (CapturedTransaction) -> Void = { _ in }
    var onSkipped: (String) -> Void = { _ in }

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        schedule(0.25)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        interval = 0
    }

    /// Accept whatever is on the pasteboard now as already seen, without importing it.
    /// Used after unlock, resume and starting capture.
    func resync() {
        lastChangeCount = pasteboard.changeCount
    }

    /// Called straight after devPaste writes to the pasteboard, so the write is never captured.
    func noteOwnWrite() {
        lastChangeCount = pasteboard.changeCount
    }

    private func schedule(_ seconds: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = seconds * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        interval = seconds
    }

    private func tick() {
        let count = pasteboard.changeCount
        if count != lastChangeCount {
            lastChangeCount = count
            lastChangeAt = Date()
            if isCapturing { captureCurrent() }
        }
        let wanted: TimeInterval = Date().timeIntervalSince(lastChangeAt) < 30 ? 0.25 : 0.75
        if wanted != interval { schedule(wanted) }
    }

    private func captureCurrent() {
        // Decide on types and source first. No payload is read for a skipped copy.
        let types = (pasteboard.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) }
        let who = attribution()
        let declaredSource = pasteboard.string(forType: NSPasteboard.PasteboardType(PBType.nsSource))
        var candidates = who.candidates
        if let declaredSource { candidates.append(declaredSource) }

        let decision = policy().decide(types: types, candidateSources: candidates)
        guard decision == .capture else {
            Log.capture.info("capture.skipped reason=\(String(describing: decision), privacy: .public)")
            return
        }

        let sourceID = declaredSource ?? who.bundleID
        let sourceName = declaredSource.flatMap(Self.appName(for:)) ?? who.name
        switch Self.snapshot(pasteboard, sourceBundleID: sourceID, sourceName: sourceName,
                             maxBytes: RetentionPolicy.maxTransactionBytes) {
        case .ok(let tx):
            onTransaction(tx)
        case .tooLarge(let bytes):
            Log.capture.info("capture.skipped reason=tooLarge bytes=\(bytes, privacy: .public)")
            onSkipped("Skipped a copy larger than 50 MB.")
        case .unstable:
            Log.capture.error("capture.missed reason=unstable")
        case .empty, .unsupported:
            break
        }
    }

    /// Reads every supported representation of every item. If the pasteboard changes mid-read,
    /// retry up to three times so one transaction is never mixed with the next.
    static func snapshot(_ pb: NSPasteboard, sourceBundleID: String?, sourceName: String?, maxBytes: Int) -> SnapshotResult {
        for _ in 0..<3 {
            let start = pb.changeCount
            guard let items = pb.pasteboardItems, !items.isEmpty else { return .empty }
            var captured: [CapturedItem] = []
            var total = 0
            var tooBig = false
            outer: for item in items {
                let available = Set(item.types.map(\.rawValue))
                var reps: [Representation] = []
                for uti in PBType.supported where available.contains(uti) {
                    guard let data = item.data(forType: NSPasteboard.PasteboardType(uti)) else { continue }
                    total += data.count
                    if total > maxBytes { tooBig = true; break outer }
                    reps.append(Representation(uti: uti, data: data))
                }
                // A bookmark lets a moved file be found again later. It is not part of the item's identity.
                if let urlData = reps.first(where: { $0.uti == PBType.fileURL })?.data,
                   let string = String(data: urlData, encoding: .utf8), let url = URL(string: string), url.isFileURL,
                   let bookmark = FileResolver.bookmark(for: url) {
                    reps.append(Representation(uti: PBType.bookmark, data: bookmark))
                }
                if !reps.isEmpty { captured.append(CapturedItem(representations: reps)) }
            }
            if pb.changeCount != start { continue }
            if tooBig { return .tooLarge(total) }
            if captured.isEmpty { return .unsupported }
            return .ok(CapturedTransaction(items: captured, sourceBundleID: sourceBundleID, sourceName: sourceName))
        }
        return .unstable
    }

    private static func appName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
