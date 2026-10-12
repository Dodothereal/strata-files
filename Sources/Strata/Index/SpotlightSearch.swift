import Foundation

/// A search only Spotlight can answer: things Strata's index doesn't record, like Finder tags. `tag:Red`,
/// `tag:"Client X"`; other words narrow by name and `ext:` by extension, as in a normal search.
nonisolated struct SpotlightQuery: Equatable, Sendable {
    var tags: [String] = []
    var words: [String] = []
    var extensions: [String] = []

    /// Nil when nothing in `text` needs Spotlight.
    static func parse(_ text: String) -> SpotlightQuery? {
        var query = SpotlightQuery()
        for token in tokens(text) {
            let lower = token.lowercased()
            if lower.hasPrefix("tag:") {
                let value = String(token.dropFirst(4))
                if !value.isEmpty { query.tags.append(value) }
            } else if lower.hasPrefix("ext:") {
                query.extensions += token.dropFirst(4).split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
                    .filter { !$0.isEmpty }
            } else {
                query.words.append(token)
            }
        }
        return query.tags.isEmpty ? nil : query
    }

    /// Every condition at once. Values are passed as arguments, never pasted into the format.
    var predicate: NSPredicate {
        var parts = tags.map { NSPredicate(format: "%K ==[c] %@", "kMDItemUserTags", $0) }
        parts += words.map { NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, $0) }
        if !extensions.isEmpty {
            parts.append(Self.any(extensions.map { NSPredicate(format: "%K ENDSWITH[c] %@", NSMetadataItemFSNameKey, "." + $0) }))
        }
        return Self.all(parts)
    }

    // NSMetadataQuery throws on a compound predicate with a single condition.
    private static func all(_ parts: [NSPredicate]) -> NSPredicate {
        parts.count == 1 ? parts[0] : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    private static func any(_ parts: [NSPredicate]) -> NSPredicate {
        parts.count == 1 ? parts[0] : NSCompoundPredicate(orPredicateWithSubpredicates: parts)
    }

    /// "Tagged “Red” and “Work” · named “report” · .pdf", for the results summary.
    var summary: String {
        var parts = ["Tagged " + ListFormatter.localizedString(byJoining: tags.map { "“\($0)”" })]
        if !words.isEmpty { parts.append("named " + ListFormatter.localizedString(byJoining: words.map { "“\($0)”" })) }
        if !extensions.isEmpty { parts.append(extensions.map { "." + $0 }.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// A tag as a query term, quoted and escaped so any name round-trips (`tag:"Client \"A\""`).
    static func term(forTag name: String) -> String {
        "tag:\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Words, with "quoted phrases" kept together (`tag:"Client X"`); inside quotes, \" and \\ stand for themselves.
    private static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if quoted, character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace, !quoted {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

/// Runs a Spotlight query to completion (or a time limit) and returns what it found.
enum SpotlightSearch {
    struct Result {
        var urls: [URL]
        var total: Int
        var timedOut: Bool
    }

    /// Searches `scope`, or the whole Mac when nil. Returns at most `limit` items, with the total found.
    static func run(_ predicate: NSPredicate, scope: URL?, limit: Int = 1000, timeout: TimeInterval = 15) async -> Result {
        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = scope.map { [$0] } ?? [NSMetadataQueryLocalComputerScope]
        let state = QueryState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.finish = { timedOut in
                    query.disableUpdates()
                    query.stop()
                    let total = query.resultCount
                    var urls: [URL] = []
                    for index in 0..<min(total, limit) {
                        if let path = (query.result(at: index) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String {
                            urls.append(URL(fileURLWithPath: path))
                        }
                    }
                    continuation.resume(returning: Result(urls: urls, total: total, timedOut: timedOut))
                }
                state.observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                                        object: query, queue: .main) { _ in
                    MainActor.assumeIsolated { state.complete(timedOut: false) }
                }
                if !query.start() { return state.complete(timedOut: false) }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { state.complete(timedOut: true) }
            }
        } onCancel: {
            Task { @MainActor in state.complete(timedOut: false) }
        }
    }

    /// The pieces a running query's callbacks share; it finishes exactly once.
    private final class QueryState {
        var observer: NSObjectProtocol?
        var finish: ((Bool) -> Void)?

        func complete(timedOut: Bool) {
            guard let finish else { return }
            self.finish = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            finish(timedOut)
        }
    }
}
