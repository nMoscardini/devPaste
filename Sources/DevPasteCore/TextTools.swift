import Foundation

/// The V1 text transformations (spec: Editing and transforms). Deterministic and Unicode-aware.
/// They work on a copy; the stored original is never changed.
public enum TextTransform: String, CaseIterable, Identifiable, Sendable {
    case upperCase, lowerCase, titleCase, trim, removeEmptyLines, normaliseLineEndings, joinPDFLines

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .upperCase: "UPPER CASE"
        case .lowerCase: "lower case"
        case .titleCase: "Title Case"
        case .trim: "Trim outer spaces"
        case .removeEmptyLines: "Remove empty lines"
        case .normaliseLineEndings: "Normalise line endings"
        case .joinPDFLines: "Join wrapped PDF lines"
        }
    }

    private static let locale = Locale(identifier: "en_GB")

    public func apply(_ text: String) -> String {
        switch self {
        case .upperCase:
            return text.uppercased(with: Self.locale)
        case .lowerCase:
            return text.lowercased(with: Self.locale)
        case .titleCase:
            return text.capitalized(with: Self.locale)
        case .trim:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .removeEmptyLines:
            return Self.lines(text)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")
        case .normaliseLineEndings:
            return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        case .joinPDFLines:
            return Self.joinWrapped(text)
        }
    }

    private static func lines(_ text: String) -> [String] {
        TextTransform.normaliseLineEndings.apply(text).components(separatedBy: "\n")
    }

    /// Heuristic, never automatic: lines inside a paragraph are joined with a space. A line ending in
    /// a hyphen before a lower-case letter is joined without the hyphen. Blank lines keep paragraphs apart.
    private static func joinWrapped(_ text: String) -> String {
        var paragraphs: [String] = []
        var current = ""
        for raw in lines(text) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.isEmpty { paragraphs.append(current); current = "" }
                continue
            }
            if current.isEmpty {
                current = line
            } else if current.hasSuffix("-"), let first = line.first, first.isLowercase {
                current.removeLast()
                current += line
            } else {
                current += " " + line
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n")
    }
}

/// Combined paste separators (spec: Combined paste).
public enum CombineSeparator: Hashable, Sendable, Identifiable, CaseIterable {
    case newLine, blankLine, comma, tab, custom

    public var id: Self { self }

    public var label: String {
        switch self {
        case .newLine: "New line"
        case .blankLine: "Blank line"
        case .comma: "Comma"
        case .tab: "Tab"
        case .custom: "Custom"
        }
    }

    public func string(custom: String) -> String {
        switch self {
        case .newLine: "\n"
        case .blankLine: "\n\n"
        case .comma: ", "
        case .tab: "\t"
        case .custom: custom
        }
    }

    public static func combine(_ texts: [String], separator: CombineSeparator, custom: String = "") -> String {
        texts.joined(separator: separator.string(custom: custom))
    }
}
