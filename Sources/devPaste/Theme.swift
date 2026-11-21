import AppKit
import Combine
import SwiftUI

/// Colour themes, the same as devThink, Recipe Vault and devInstagram (Golden, Dark Slate, Marine,
/// Madder), plus System (the Mac's own look, the default). Every colour can be changed in
/// Settings > Colours and reset to the original. A setting on this Mac only.
///
/// Area colours (AreaStyle.swift) stay the accent in the panel on every theme. Both pass 3:1 on
/// white and black, so they hold on light and dark themes. The theme accent tints Settings only.
enum ThemeName: String, CaseIterable, Identifiable, Codable {
    case system, golden, slate, marine, madder
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .golden: "Golden"
        case .slate: "Dark Slate"
        case .marine: "Marine"
        case .madder: "Madder"
        }
    }

    /// Dark Slate is dark; the others are light. System follows the Mac.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .slate: .dark
        default: .light
        }
    }

    var original: ThemePalette? {
        switch self {
        case .system: nil
        case .golden: ThemePalette(background: "#faf5e4", panel: "#fffdf7", border: "#e8dcb3", text: "#24200a",
                                   secondaryText: "#6b6142", faintText: "#a89b6e", accent: "#007e5e", dot: "#f8c829")
        case .slate: ThemePalette(background: "#141618", panel: "#1c1f22", border: "#2a2e32", text: "#e8eaec",
                                  secondaryText: "#8a9099", faintText: "#5d6670", accent: "#5b9bd5", dot: "#3a3f45")
        case .marine: ThemePalette(background: "#f2f1e6", panel: "#fbfbf4", border: "#d6d4bd", text: "#171a24",
                                   secondaryText: "#55586a", faintText: "#8b8e78", accent: "#2f4d9b", dot: "#2f4d9b")
        case .madder: ThemePalette(background: "#fdf9f8", panel: "#ffffff", border: "#ecdedb", text: "#1c1210",
                                   secondaryText: "#6b5a56", faintText: "#a3928d", accent: "#a21721", dot: "#a21721")
        }
    }
}

struct ThemePalette: Codable, Equatable {
    var background: String
    var panel: String
    var border: String
    var text: String
    var secondaryText: String
    var faintText: String
    var accent: String
    var dot: String

    /// The editable fields, in the order Settings shows them.
    /// Computed, not stored: key paths are not Sendable, and the package builds in Swift 6 mode.
    static var fields: [(WritableKeyPath<ThemePalette, String>, String)] { [
        (\.background, "Background"), (\.panel, "Cards and editors"), (\.border, "Borders"),
        (\.text, "Main text"), (\.secondaryText, "Secondary text"), (\.faintText, "Faint text"),
        (\.accent, "Accent (Settings)"), (\.dot, "Theme dot"),
    ] }
}

/// The chosen theme, any edits, and translucency. Kept in UserDefaults; no clipboard content.
final class ThemeStore: ObservableObject {
    private enum Key {
        static let selected = "theme.selected"
        static let overrides = "theme.overrides"
        static let translucency = "theme.translucency"
    }

    @Published var selected: ThemeName {
        didSet { UserDefaults.standard.set(selected.rawValue, forKey: Key.selected) }
    }
    @Published private(set) var overrides: [String: ThemePalette]
    /// How much of the desktop shows through, 0 (solid) to 1 (almost clear). Text and controls
    /// stay solid; only backgrounds thin. Same curve as devThink and devTrain (TranslucencyCurve).
    @Published var translucency: Double {
        didSet { UserDefaults.standard.set(translucency, forKey: Key.translucency) }
    }

    init() {
        translucency = min(max(UserDefaults.standard.double(forKey: Key.translucency), 0), 1)
        selected = ThemeName(rawValue: UserDefaults.standard.string(forKey: Key.selected) ?? "") ?? .system
        if let data = UserDefaults.standard.data(forKey: Key.overrides),
           let saved = try? JSONDecoder().decode([String: ThemePalette].self, from: data) {
            overrides = saved
        } else {
            overrides = [:]
        }
    }

    /// The colours in use, or nil for System.
    var palette: ThemePalette? { palette(for: selected) }

    func palette(for theme: ThemeName) -> ThemePalette? {
        overrides[theme.rawValue] ?? theme.original
    }

    func isEdited(_ theme: ThemeName) -> Bool { overrides[theme.rawValue] != nil }

    func set(_ field: WritableKeyPath<ThemePalette, String>, to hex: String, in theme: ThemeName) {
        guard var p = palette(for: theme) else { return }
        p[keyPath: field] = hex
        overrides[theme.rawValue] = p
        save()
    }

    func reset(_ theme: ThemeName) {
        overrides[theme.rawValue] = nil
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(overrides) { UserDefaults.standard.set(data, forKey: Key.overrides) }
    }
}

/// Colours for the few views that draw their own boxes. `card` is always solid: editors and
/// previews sit on it, and reading comes first (VISUAL_DESIGN rule 7).
struct ThemeColours: Equatable {
    var card: Color = Color(nsColor: .windowBackgroundColor)
    var panel: Color = Color.secondary.opacity(0.08)
    var border: Color = Color.secondary.opacity(0.25)
}

extension EnvironmentValues {
    @Entry var themeColours = ThemeColours()
}

/// Applies the theme to a window's root view. Always the same modifiers, so switching theme
/// never rebuilds the views (no lost scroll position or selection).
///
/// devPaste's windows are AppKit windows hosting SwiftUI, not SwiftUI window scenes, so
/// `devWindowBackground` (which paints the scene's window container) does not reach them. This
/// draws the same thing as a background instead: a behind-window blur under the base colour,
/// both on TranslucencyCurve, with TranslucentWindow making the window see-through.
struct Themed: ViewModifier {
    @ObservedObject var theme: ThemeStore
    /// The panel never makes devPaste the active app (the app you paste into stays in front), so
    /// its blur must stay on. Other windows go flat when not in use, as every Mac window does.
    var alwaysActive = false
    /// False for a window that keeps its own clear background and rounded shape (the carousel).
    var ownsWindow = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let p = theme.palette
        let see = reduceTransparency ? 0 : theme.translucency
        let base = p.map { Color(devHex: $0.background) } ?? Color(nsColor: .windowBackgroundColor)
        content
            .foregroundStyle(p.map { Color(devHex: $0.text) } ?? Color.primary,
                             p.map { Color(devHex: $0.secondaryText) } ?? Color.secondary,
                             p.map { Color(devHex: $0.faintText) } ?? Color(nsColor: .tertiaryLabelColor))
            .tint(p.map { Color(devHex: $0.accent) })
            .scrollContentBackground(p == nil && see == 0 ? .automatic : .hidden)
            .background {
                ZStack {
                    BehindWindowBlur(alwaysActive: alwaysActive).opacity(TranslucencyCurve.blur(see))
                    base.opacity(TranslucencyCurve.colour(see))
                }
                .ignoresSafeArea()
                .accessibilityHidden(true)
            }
            .background(TranslucentWindow(enabled: ownsWindow && see > 0))
            .background(WindowAppearance(scheme: theme.selected.colorScheme))
            .environment(\.themeColours, p.map {
                ThemeColours(card: Color(devHex: $0.panel), panel: Color(devHex: $0.panel), border: Color(devHex: $0.border))
            } ?? ThemeColours())
    }
}

/// A frosted blur of whatever is behind the window. Draws nothing of its own.
struct BehindWindowBlur: NSViewRepresentable {
    var alwaysActive: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .sidebar
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.state = alwaysActive ? .active : .followsWindowActiveState
    }
}

/// Sets the hosting window's light or dark appearance from the theme (nil follows the Mac).
struct WindowAppearance: NSViewRepresentable {
    let scheme: ColorScheme?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let appearance: NSAppearance?
        switch scheme {
        case .some(.dark): appearance = NSAppearance(named: .darkAqua)
        case .some(.light): appearance = NSAppearance(named: .aqua)
        default: appearance = nil
        }
        DispatchQueue.main.async { view.window?.appearance = appearance }
    }
}

extension Color {
    /// #rrggbb for storing a colour picked in Settings.
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
