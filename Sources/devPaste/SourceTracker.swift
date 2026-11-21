import AppKit

/// Best-effort source app attribution (spec: Capture). Tracks recent app switches so that a copy
/// made just as the user switched apps is attributed as Unknown, and every app that could have
/// made it is checked against the exclusion list.
final class SourceTracker {
    private var recent: [(bundleID: String, name: String?, at: Date)] = []
    private var observer: NSObjectProtocol?
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "com.nino.devPaste"

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            self.recent.append((bundleID: id, name: app.localizedName, at: Date()))
            self.recent.removeAll { Date().timeIntervalSince($0.at) > 5 }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    struct Attribution {
        /// Every app that could have made the copy. Used for exclusions.
        let candidates: [String]
        /// The app shown in the list. nil means Unknown.
        let bundleID: String?
        let name: String?
    }

    func attribute(now: Date = Date()) -> Attribution {
        let front = NSWorkspace.shared.frontmostApplication
        var candidates = recent.filter { now.timeIntervalSince($0.at) < 1.5 }.map(\.bundleID)
        if let id = front?.bundleIdentifier { candidates.append(id) }

        let switchedJustNow = recent.contains { now.timeIntervalSince($0.at) < 0.4 }
        guard let front, let id = front.bundleIdentifier, id != ownBundleID, !switchedJustNow else {
            return Attribution(candidates: candidates, bundleID: nil, name: nil)
        }
        return Attribution(candidates: candidates, bundleID: id, name: front.localizedName)
    }
}
