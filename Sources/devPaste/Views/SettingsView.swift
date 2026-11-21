import SwiftUI
import ServiceManagement
import DevPasteCore

struct SnippetShortcutEntry: Identifiable {
    let id: String
    let name: String
    let shortcut: SnippetShortcut
}

/// What the Settings window asks AppController to do.
struct SettingsActions {
    var applyPanelShortcut: (SnippetShortcut) -> String?
    var applyQueueShortcut: (_ next: Bool, SnippetShortcut?) -> String?
    var applySnippetShortcutsEnabled: (Bool) -> Void
    var clearSnippetShortcut: (String) -> Void
    var backupNow: () -> Void
    var chooseBackupFolder: () -> Void
    var restoreSnippets: () -> Void
    var exportAllSnippets: () -> Void
    var importSnippets: () -> Void
    var deleteAllOCR: () -> Void
    var setOCREnabled: (Bool) -> Void
    var confirmDeleteAll: (Bool) -> Void
    var snippetShortcuts: () -> [SnippetShortcutEntry]
    var shortcutProblems: () -> [String: String]
}

/// Settings window: General, Shortcuts, Capture, Privacy, Data, Colours (spec: Settings).
/// Resizable; size and position are remembered.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: AppModel
    @ObservedObject var theme: ThemeStore
    let historyFolder: URL
    let snippetFolder: URL
    let actions: SettingsActions

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutsTab(settings: settings, actions: actions)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            CaptureTab(settings: settings, model: model, actions: actions)
                .tabItem { Label("Capture", systemImage: "doc.on.clipboard") }
            PrivacyTab(settings: settings, model: model)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            DataTab(settings: settings, model: model, historyFolder: historyFolder, snippetFolder: snippetFolder, actions: actions)
                .tabItem { Label("Data", systemImage: "externaldrive") }
            ColourSettings(theme: theme)
                .tabItem { Label("Colours", systemImage: "paintpalette") }
        }
        .padding(.top, 8)
        .frame(minWidth: 560, idealWidth: 620, maxWidth: .infinity, minHeight: 460, idealHeight: 560, maxHeight: .infinity)
        .environment(\.areaAccent, PanelSection.clipboard.accent)
    }
}

// MARK: General

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Panel") {
                Toggle("Keep the last search when reopening", isOn: $settings.retainQuery)
                Toggle("Keep the panel open after clicking elsewhere", isOn: $settings.keepOpen)
            }
            Section {
                Picker("Show", selection: $settings.carouselSource) {
                    ForEach(CarouselSource.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Right-click the menu bar icon")
            } footer: {
                Text("Drops down pictures of your last 4 copies, or your first 4 snippets in the order set in Quick Snippets. Click one, or press 1 to 4, to copy it, then press ⌘V. Control-click works too. A left click still opens the menu.")
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not change this: \(error.localizedDescription). Move devPaste to Applications and try again."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: Shortcuts

private struct ShortcutsTab: View {
    @ObservedObject var settings: AppSettings
    let actions: SettingsActions
    @State private var refresh = 0

    var body: some View {
        Form {
            Section("devPaste") {
                ShortcutField(title: "Open the panel", current: settings.hotKeyLabel, apply: actions.applyPanelShortcut)
                ShortcutField(title: "Paste next from queue", current: settings.queueNextShortcut?.label,
                              apply: { actions.applyQueueShortcut(true, $0) },
                              clear: { _ = actions.applyQueueShortcut(true, nil) })
                ShortcutField(title: "Resend last queue item", current: settings.queueBackShortcut?.label,
                              apply: { actions.applyQueueShortcut(false, $0) },
                              clear: { _ = actions.applyQueueShortcut(false, nil) })
            }
            Section {
                Toggle("Snippet shortcuts on", isOn: Binding(get: { settings.snippetShortcutsEnabled },
                                                            set: { actions.applySnippetShortcutsEnabled($0); refresh += 1 }))
                let list = actions.snippetShortcuts()
                let problems = actions.shortcutProblems()
                if list.isEmpty {
                    Text("No snippet has a shortcut. Add one in the snippet editor.").foregroundStyle(.secondary)
                }
                ForEach(list) { entry in
                    HStack {
                        Text(entry.name)
                        Spacer()
                        if let problem = problems[entry.id] {
                            Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(entry.shortcut.label).font(.body.monospaced())
                        Button("Remove") { actions.clearSnippetShortcut(entry.id); refresh += 1 }
                    }
                }
                .id(refresh)
            } header: {
                Text("Snippet shortcuts")
            } footer: {
                Text("devPaste checks its own shortcuts and other snippets. It cannot see every shortcut other apps use, so test a new one in the apps you use most.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Capture

private struct CaptureTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: AppModel
    let actions: SettingsActions

    var body: some View {
        Form {
            Section {
                Toggle("Capture what I copy", isOn: Binding(
                    get: { settings.captureStarted },
                    set: { on in if on { model.startCapture() } else { settings.captureStarted = false } }))
                if let text = model.pauseText {
                    HStack {
                        Label(text, systemImage: "pause.circle.fill")
                        Spacer()
                        Button("Resume") { model.resume() }
                    }
                }
            } footer: {
                Text("Turning capture on never imports what was copied while it was off.")
            }
            Section("Keep history for") {
                Picker("Keep history for", selection: $settings.retentionDays) {
                    ForEach(AppSettings.retentionChoices, id: \.self) { Text(AppSettings.retentionLabel($0)).tag($0) }
                }
                .labelsHidden()
                Text("At most 10,000 items and 1 GB. The oldest unpinned items go first. Pinned items never expire. One copy can be at most 50 MB.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Keep duplicates", isOn: $settings.keepDuplicates)
            }
            Section {
                Toggle("Recognise text in copied images", isOn: Binding(get: { settings.ocrEnabled }, set: actions.setOCREnabled))
                Button("Delete all recognised text…") { actions.deleteAllOCR() }
            } header: {
                Text("Text in images")
            } footer: {
                Text("Runs on this Mac only, in the background. Recognised text becomes searchable; the image is kept. English to start.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Privacy

private struct PrivacyTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: AppModel
    @State private var hasAccess = PasteCoordinator.hasAccessibility

    var body: some View {
        Form {
            Section {
                ForEach(settings.excludedBundleIDs, id: \.self) { id in
                    HStack {
                        Text(Self.name(for: id))
                        Text(id).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            settings.excludedBundleIDs.removeAll { $0 == id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Stop excluding \(Self.name(for: id))")
                    }
                }
                Menu("Add a running app") {
                    ForEach(runningApps, id: \.bundleID) { app in
                        Button(app.name) { settings.excludedBundleIDs.append(app.bundleID) }
                    }
                }
            } header: {
                Text("Never capture from these apps")
            } footer: {
                Text("Copies that apps mark as private (most password managers) are always skipped. Detection is not perfect, so exclude any app whose copies you never want kept.")
            }

            Section("Pause and present") {
                if let text = model.pauseText {
                    HStack { Label(text, systemImage: "pause.circle.fill"); Spacer(); Button("Resume") { model.resume() } }
                } else {
                    HStack {
                        Button("5 minutes") { model.pause(seconds: 300) }
                        Button("15 minutes") { model.pause(seconds: 900) }
                        Button("1 hour") { model.pause(seconds: 3600) }
                        Button("Until resumed") { model.pause(seconds: nil) }
                    }
                }
                Toggle("Presentation mode (hide previews, pause capture)",
                       isOn: Binding(get: { model.presentation }, set: { model.setPresentation($0) }))
                Text("Capture also stops while the screen is locked. devPaste cannot reliably tell when you share your screen, so turn Presentation mode on before you present.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Label(hasAccess ? "Direct paste is on" : "Direct paste is off",
                          systemImage: hasAccess ? "checkmark.circle.fill" : "xmark.circle")
                    Spacer()
                    if !hasAccess {
                        Button("Ask for access") { PasteCoordinator.requestAccessibility() }
                    }
                    Button("Open Accessibility Settings") { PasteCoordinator.openAccessibilitySettings() }
                }
            } header: {
                Text("Accessibility")
            } footer: {
                Text("Needed to paste straight into the app you came from. Without it devPaste copies the item and you press ⌘V.")
            }
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            hasAccess = PasteCoordinator.hasAccessibility
        }
    }

    private var runningApps: [SourceApp] {
        let excluded = Set(settings.excludedBundleIDs)
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> SourceApp? in
                guard let id = app.bundleIdentifier, !excluded.contains(id), id != Bundle.main.bundleIdentifier else { return nil }
                return SourceApp(bundleID: id, name: app.localizedName ?? id)
            }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: Data

private struct DataTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: AppModel
    let historyFolder: URL
    let snippetFolder: URL
    let actions: SettingsActions

    var body: some View {
        Form {
            Section {
                LabeledContent("Snippets", value: "\(model.snippetCount)")
                LabeledContent("Last backup") {
                    Text(settings.lastBackupMessage).multilineTextAlignment(.trailing).foregroundStyle(.secondary)
                }
                LabeledContent("NAS folder") {
                    HStack {
                        Text(settings.backupFolderPath ?? "Not chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { actions.chooseBackupFolder() }
                        if settings.backupFolderPath != nil {
                            Button("Clear") { settings.backupFolderPath = nil }
                        }
                    }
                }
                HStack {
                    Button("Back up now") { actions.backupNow() }
                    Button("Restore from a backup…") { actions.restoreSnippets() }
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([snippetFolder]) }
                }
            } header: {
                Text("Quick Snippets (backed up)")
            } footer: {
                Text("Every day devPaste writes a copy of your snippets on this Mac, keeps the last 14, and copies it to the NAS folder. Test a restore once so you know it works.")
            }
            Section("Export and import") {
                HStack {
                    Button("Export all snippets…") { actions.exportAllSnippets() }
                    Button("Import…") { actions.importSnippets() }
                }
                Text("Export writes a JSON file you can keep anywhere. It is not encrypted, so treat it like the content itself. Import adds new snippets and never replaces existing ones.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Items", value: "\(model.stats.count)")
                LabeledContent("Pinned", value: "\(model.stats.pinnedCount)")
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: model.stats.bytes, countStyle: .file))
                HStack {
                    Button("Delete last hour") { model.deleteRecent(seconds: 3600) }
                    Button("Delete all, keep pinned…") { actions.confirmDeleteAll(false) }
                    Button("Delete all…", role: .destructive) { actions.confirmDeleteAll(true) }
                }
                Button("Show history folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([historyFolder]) }
            } header: {
                Text("Clipboard history (never backed up)")
            } footer: {
                Text("History is temporary. It is kept out of Time Machine and every backup.")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.reload() }
    }
}

// MARK: Colours

/// The same themes as devThink, plus System. Click a dot to switch. Every colour of a theme can
/// be changed and reset. Transparency uses the shared curve (VISUAL_DESIGN rule 9).
private struct ColourSettings: View {
    @ObservedObject var theme: ThemeStore

    var body: some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    ForEach(ThemeName.allCases) { name in
                        ThemeDot(name: name, theme: theme)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Theme")
            } footer: {
                Text("System uses your Mac's own look and follows Light and Dark. The others are fixed palettes; Dark Slate is dark. Clipboard stays teal and Quick Snippets purple on every theme.")
            }
            Section {
                Slider(value: $theme.translucency, in: 0...1) {
                    Text("Transparency")
                } minimumValueLabel: {
                    Image(systemName: "square.fill").accessibilityLabel("Solid")
                } maximumValueLabel: {
                    Image(systemName: "square.dashed").accessibilityLabel("See-through")
                }
                Button("Make solid") { theme.translucency = 0 }
                    .disabled(theme.translucency == 0)
            } header: {
                Text("Transparency")
            } footer: {
                Text("Left half: the colour thins over a frosted blur of your desktop. Right half: the blur fades too, until the window is almost clear. Text, editors and previews stay solid. The panel stays frosted while you work in another app. Reduce Transparency in System Settings > Accessibility > Display turns it off.")
            }

            if let palette = theme.palette(for: theme.selected), theme.selected != .system {
                Section("Edit \(theme.selected.label)") {
                    ForEach(Array(ThemePalette.fields.enumerated()), id: \.offset) { _, entry in
                        let (field, label) = entry
                        ColorPicker(label, selection: Binding(
                            get: { Color(devHex: palette[keyPath: field]) },
                            set: { theme.set(field, to: $0.hexString, in: theme.selected) }),
                                    supportsOpacity: false)
                    }
                    Button("Reset to Original") { theme.reset(theme.selected) }
                        .disabled(!theme.isEdited(theme.selected))
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ThemeDot: View {
    let name: ThemeName
    @ObservedObject var theme: ThemeStore

    var body: some View {
        let selected = theme.selected == name
        Button { theme.selected = name } label: {
            VStack(spacing: 6) {
                Group {
                    if let p = theme.palette(for: name) {
                        Circle().fill(Color(devHex: p.dot))
                            .overlay(Circle().inset(by: 7).fill(Color(devHex: p.background)))
                    } else {
                        Circle().fill(LinearGradient(colors: [.white, .black], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                }
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: selected ? 3 : 1))
                Text(name.label).font(.caption)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name.label) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
