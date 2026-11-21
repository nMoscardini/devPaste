import Foundation

/// Turns what the user types into an FTS5 MATCH expression (spec: Search).
/// Words must all match (AND). Each word matches as a prefix. "Quoted phrases" match exactly.
/// Everything is quoted, so user input can never break the FTS syntax.
public enum SearchQuery {
    public enum Term: Equatable {
        case word(String)
        case phrase(String)
    }

    public static func terms(_ query: String) -> [Term] {
        let normalised = query.precomposedStringWithCompatibilityMapping
        var terms: [Term] = []
        var current = ""
        var inQuote = false

        func flushWord() {
            let w = current.trimmingCharacters(in: .whitespaces)
            if hasSearchableCharacter(w) { terms.append(.word(w)) }
            current = ""
        }
        func flushPhrase() {
            let p = current.trimmingCharacters(in: .whitespaces)
            if hasSearchableCharacter(p) { terms.append(.phrase(p)) }
            current = ""
        }

        for ch in normalised {
            if ch == "\"" {
                if inQuote { flushPhrase() } else { flushWord() }
                inQuote.toggle()
            } else if ch.isWhitespace && !inQuote {
                flushWord()
            } else {
                current.append(ch)
            }
        }
        if inQuote { flushPhrase() } else { flushWord() }
        return terms
    }

    public static func ftsExpression(_ query: String) -> String? {
        let parts = terms(query).map { term -> String in
            switch term {
            case .word(let w): return quote(w) + "*"
            case .phrase(let p): return quote(p)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func hasSearchableCharacter(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
