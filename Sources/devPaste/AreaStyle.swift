import SwiftUI

/// The two views are devPaste's areas (VISUAL_DESIGN.md section 4, step 2). Colours live here only.
/// Both checked against rule 1 on 20 November 2026:
///   Clipboard #1E8A9E - 4.05:1 on white, 5.18:1 on black.
///   Quick Snippets #8A5CD6 - 4.58:1 on white, 4.58:1 on black.
/// Colour never carries meaning alone: the segmented control labels and symbols say the same thing.
enum PanelSection: String, CaseIterable, Identifiable {
    case clipboard, snippets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboard: "Clipboard"
        case .snippets: "Quick Snippets"
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: "doc.on.clipboard"
        case .snippets: "text.badge.star"
        }
    }

    var accent: Color {
        switch self {
        case .clipboard: Color(devHex: "#1E8A9E")
        case .snippets: Color(devHex: "#8A5CD6")
        }
    }
}

/// devPaste's tuning of AccentWash (VISUAL_DESIGN 1.1, tuning). Much lighter than standard, and gone
/// by mid-panel, so the list and preview read as before. Kept here, next to the area colours.
enum PanelWash {
    static let top = 0.16
    static let upper = 0.06
    static let middle = 0.0
    static let glow = 0.10
}
