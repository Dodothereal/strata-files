import Foundation

/// Keep the spelling of terms while editing a filter. Quoted phrases and escaped quotes must round-trip.
nonisolated package enum SearchTerms {
    package struct Term: Sendable {
        package let raw: String
        package let value: String
        package let isComplete: Bool
        package var key: String? { value.firstIndex(of: ":").map { value[..<$0].lowercased() } }
    }

    package static func split(_ text: String) -> [Term] {
        var result: [Term] = []
        var raw = "", value = ""
        var quoted = false, escaped = false
        func finish() {
            if !raw.isEmpty { result.append(Term(raw: raw, value: value, isComplete: !quoted && !escaped)) }
            raw = ""; value = ""
        }
        for character in text {
            if character.isWhitespace && !quoted && !escaped { finish(); continue }
            raw.append(character)
            if escaped {
                if character != "\\" && character != "\"" { value.append("\\") }
                value.append(character); escaped = false
            }
            else if quoted && character == "\\" { escaped = true }
            else if character == "\"" { quoted.toggle() }
            else { value.append(character) }
        }
        if escaped { value.append("\\") }
        finish()
        return result
    }

    package static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
