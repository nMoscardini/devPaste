import Foundation
import Carbon.HIToolbox
import DevPasteCore

/// User settings, kept in UserDefaults. Settings are not secrets and hold no clipboard content.
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "onboarded") } }
    /// Capture runs only after Nino chooses Start capture (spec: Privacy).
    @Published var captureStarted: Bool { didSet { defaults.set(captureStarted, forKey: "captureStarted") } }
    /// 1, 7, 30, 90, or 0 for "until removed".
    @Published var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: "retentionDays") } }
    @Published var keepDuplicates: Bool { didSet { defaults.set(keepDuplicates, forKey: "keepDuplicates") } }
    @Published var excludedBundleIDs: [String] { didSet { defaults.set(excludedBundleIDs, forKey: "excludedBundleIDs") } }
    @Published var retainQuery: Bool { didSet { defaults.set(retainQuery, forKey: "retainQuery") } }
    @Published var keepOpen: Bool { didSet { defaults.set(keepOpen, forKey: "keepOpen") } }
    @Published var accessibilityPrompted: Bool { didSet { defaults.set(accessibilityPrompted, forKey: "accessibilityPrompted") } }

    @Published var ocrEnabled: Bool { didSet { defaults.set(ocrEnabled, forKey: "ocrEnabled") } }
    @Published var snippetShortcutsEnabled: Bool { didSet { defaults.set(snippetShortcutsEnabled, forKey: "snippetShortcutsEnabled") } }
    @Published var snippetSort: SnippetSort { didSet { defaults.set(snippetSort.rawValue, forKey: "snippetSort") } }
    /// Queue shortcuts have no default (spec: Keyboard). nil means not set.
    @Published var queueNextShortcut: SnippetShortcut? { didSet { Self.save(queueNextShortcut, "queueNextShortcut", defaults) } }
    @Published var queueBackShortcut: SnippetShortcut? { didSet { Self.save(queueBackShortcut, "queueBackShortcut", defaults) } }
    /// Folder on the NAS for the daily snippet backup. nil means this Mac only.
    @Published var backupFolderPath: String? { didSet { defaults.set(backupFolderPath, forKey: "backupFolderPath") } }
    @Published var lastBackupAt: Date? { didSet { defaults.set(lastBackupAt, forKey: "lastBackupAt") } }
    @Published var lastBackupMessage: String { didSet { defaults.set(lastBackupMessage, forKey: "lastBackupMessage") } }

    /// What right-clicking the menu bar icon shows: the last 4 copies or the first 4 snippets.
    @Published var carouselSource: CarouselSource { didSet { defaults.set(carouselSource.rawValue, forKey: "carouselSource") } }

    @Published var hotKeyCode: UInt32 { didSet { defaults.set(Int(hotKeyCode), forKey: "hotKeyCode") } }
    @Published var hotKeyModifiers: UInt32 { didSet { defaults.set(Int(hotKeyModifiers), forKey: "hotKeyModifiers") } }
    @Published var hotKeyLabel: String { didSet { defaults.set(hotKeyLabel, forKey: "hotKeyLabel") } }

    /// Control Option V. Avoids Command Shift V (VS Code Markdown preview) and Control 1 to 9 (Mission Control).
    static let defaultHotKeyCode = UInt32(kVK_ANSI_V)
    static let defaultHotKeyModifiers = UInt32(controlKey | optionKey)
    static let defaultHotKeyLabel = "⌃⌥V"
    static let retentionChoices = [1, 7, 30, 90, 0]

    init() {
        onboarded = defaults.bool(forKey: "onboarded")
        captureStarted = defaults.bool(forKey: "captureStarted")
        retentionDays = defaults.object(forKey: "retentionDays") as? Int ?? 30
        keepDuplicates = defaults.bool(forKey: "keepDuplicates")
        excludedBundleIDs = defaults.stringArray(forKey: "excludedBundleIDs") ?? CapturePolicy.defaultExcludedApps
        retainQuery = defaults.bool(forKey: "retainQuery")
        keepOpen = defaults.bool(forKey: "keepOpen")
        accessibilityPrompted = defaults.bool(forKey: "accessibilityPrompted")
        hotKeyCode = (defaults.object(forKey: "hotKeyCode") as? Int).map { UInt32($0) } ?? Self.defaultHotKeyCode
        hotKeyModifiers = (defaults.object(forKey: "hotKeyModifiers") as? Int).map { UInt32($0) } ?? Self.defaultHotKeyModifiers
        hotKeyLabel = defaults.string(forKey: "hotKeyLabel") ?? Self.defaultHotKeyLabel
        ocrEnabled = defaults.object(forKey: "ocrEnabled") as? Bool ?? true
        snippetShortcutsEnabled = defaults.object(forKey: "snippetShortcutsEnabled") as? Bool ?? true
        snippetSort = SnippetSort(rawValue: defaults.string(forKey: "snippetSort") ?? "") ?? .favouritesFirst
        queueNextShortcut = Self.load("queueNextShortcut", defaults)
        queueBackShortcut = Self.load("queueBackShortcut", defaults)
        backupFolderPath = defaults.string(forKey: "backupFolderPath")
        lastBackupAt = defaults.object(forKey: "lastBackupAt") as? Date
        lastBackupMessage = defaults.string(forKey: "lastBackupMessage") ?? "No backup yet."
        carouselSource = CarouselSource(rawValue: defaults.string(forKey: "carouselSource") ?? "") ?? .copies
    }

    var panelShortcut: SnippetShortcut {
        SnippetShortcut(keyCode: hotKeyCode, modifiers: hotKeyModifiers, label: hotKeyLabel)
    }

    private static func save(_ shortcut: SnippetShortcut?, _ key: String, _ defaults: UserDefaults) {
        if let shortcut {
            defaults.set(["code": Int(shortcut.keyCode), "mods": Int(shortcut.modifiers), "label": shortcut.label], forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func load(_ key: String, _ defaults: UserDefaults) -> SnippetShortcut? {
        guard let d = defaults.dictionary(forKey: key), let code = d["code"] as? Int, let mods = d["mods"] as? Int,
              let label = d["label"] as? String else { return nil }
        return SnippetShortcut(keyCode: UInt32(code), modifiers: UInt32(mods), label: label)
    }

    var retentionPolicy: RetentionPolicy {
        RetentionPolicy(maxAge: retentionDays == 0 ? nil : TimeInterval(retentionDays) * 86_400)
    }

    var capturePolicy: CapturePolicy {
        CapturePolicy(excludedBundleIDs: Set(excludedBundleIDs))
    }

    static func retentionLabel(_ days: Int) -> String {
        switch days {
        case 0: "Until removed"
        case 1: "1 day"
        default: "\(days) days"
        }
    }
}

/// What the right-click carousel shows.
enum CarouselSource: String, CaseIterable, Identifiable {
    case copies, snippets
    var id: String { rawValue }

    var label: String {
        switch self {
        case .copies: "Last 4 copies"
        case .snippets: "First 4 snippets"
        }
    }
}
