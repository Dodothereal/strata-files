import Foundation

/// A search only Spotlight can answer: things Strata's index doesn't record, like Finder tags and what's inside files'
/// metadata. `tag:Red`, `tag:"Client X"`, `camera:iphone`, `width:>1920`, `height:<1000`, `duration:>10m`, `pages:>20`,
/// `author:Ana`, `artist:"Miles Davis"`; with them, `kind:` (image, video, audio, pdf), other words (by name) and `ext:`
/// narrow it down, as in a normal search. A few plain-English forms read the same way ("photos taken with iPhone",
/// "videos longer than 10 minutes").
nonisolated struct SpotlightQuery: Equatable, Sendable {
    var tags: [String] = []
    var words: [String] = []
    var extensions: [String] = []
    var conditions: [Condition] = []

    /// One metadata test: text found in any of `attributes`, or a number compared with `value`.
    struct Condition: Equatable, Sendable {
        enum Test: Equatable, Sendable {
            case contains(String)
            case equals(String)
            case compare(Comparison, Double)
        }

        enum Comparison: String, Sendable {
            case greater = ">", greaterOrEqual = ">=", less = "<", lessOrEqual = "<=", equal = "=="
        }

        let attributes: [String]
        let test: Test
        /// "camera “iPhone”", "longer than 10 min", for the results summary.
        let label: String
        /// `kind:` only narrows a metadata search; on its own it's the index's job.
        var isKind = false
    }

    /// Nil when nothing in `text` needs Spotlight.
    static func parse(_ text: String) -> SpotlightQuery? {
        var query = SpotlightQuery()
        for token in tokens(naturalForm(text) ?? text) {
            let lower = token.lowercased()
            // The index's own options mean nothing to Spotlight (it ignores case anyway).
            if lower.hasPrefix("case:") || lower.hasPrefix("regex:") || lower.hasPrefix("re:") { continue }
            if lower.hasPrefix("tag:") {
                let value = String(token.dropFirst(4))
                if !value.isEmpty { query.tags.append(value) }
            } else if lower.hasPrefix("ext:") {
                query.extensions += token.dropFirst(4).split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
                    .filter { !$0.isEmpty }
            } else if let condition = condition(token) {
                query.conditions.append(condition)
            } else {
                query.words.append(token)
            }
        }
        // An artist is music's: without a kind, fonts and templates (which have "authors") would match too.
        if query.conditions.contains(where: { $0.label.hasPrefix("artist") }), !query.conditions.contains(where: \.isKind) {
            var audio = Condition(attributes: ["kMDItemContentTypeTree"], test: .equals("public.audio"), label: "audio")
            audio.isKind = true
            query.conditions.insert(audio, at: 0)
        }
        return query.tags.isEmpty && !query.conditions.contains(where: { !$0.isKind }) ? nil : query
    }

    /// `key:value` for the metadata keys, or nil.
    private static func condition(_ token: String) -> Condition? {
        guard let colon = token.firstIndex(of: ":") else { return nil }
        let key = token[..<colon].lowercased()
        let value = String(token[token.index(after: colon)...])
        guard !value.isEmpty else { return nil }
        switch key {
        case "camera", "device":
            return Condition(attributes: ["kMDItemAcquisitionModel", "kMDItemAcquisitionMake"], test: .contains(value),
                             label: "camera “\(value)”")
        case "author", "by":
            // Authors only: kMDItemCreator is the app that made the file.
            return Condition(attributes: ["kMDItemAuthors"], test: .contains(value), label: "by “\(value)”")
        case "artist":
            return Condition(attributes: ["kMDItemAuthors", "kMDItemComposer"], test: .contains(value), label: "artist “\(value)”")
        case "width", "height", "pages":
            guard let (comparison, number) = comparison(value, units: [:]) else { return nil }
            let attribute = key == "width" ? "kMDItemPixelWidth" : key == "height" ? "kMDItemPixelHeight" : "kMDItemNumberOfPages"
            let noun = key == "pages" ? "pages" : key == "width" ? "px wide" : "px high"
            return Condition(attributes: [attribute], test: .compare(comparison, number),
                             label: "\(describe(comparison)) \(Int(number)) \(noun)")
        case "duration", "length":
            let units: [String: Double] = ["s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1, "m": 60, "min": 60, "mins": 60,
                                           "minute": 60, "minutes": 60, "h": 3600, "hr": 3600, "hour": 3600, "hours": 3600]
            guard let (comparison, seconds) = comparison(value, units: units) else { return nil }
            let words: [Condition.Comparison: String] = [.greater: "longer than", .greaterOrEqual: "at least", .less: "shorter than",
                                               .lessOrEqual: "at most", .equal: "exactly"]
            return Condition(attributes: ["kMDItemDurationSeconds"], test: .compare(comparison, seconds),
                             label: "\(words[comparison] ?? "") \(duration(seconds))")
        case "kind", "type", "is":
            let types: [String: (String, String)] = [
                "image": ("public.image", "images"), "images": ("public.image", "images"), "photo": ("public.image", "images"),
                "photos": ("public.image", "images"), "picture": ("public.image", "images"), "pictures": ("public.image", "images"),
                "video": ("public.movie", "videos"), "videos": ("public.movie", "videos"), "movie": ("public.movie", "videos"),
                "movies": ("public.movie", "videos"), "audio": ("public.audio", "audio"), "music": ("public.audio", "audio"),
                "song": ("public.audio", "audio"), "songs": ("public.audio", "audio"), "pdf": ("com.adobe.pdf", "PDFs"),
                "pdfs": ("com.adobe.pdf", "PDFs"), "text": ("public.text", "text"), "presentation": ("public.presentation", "presentations"),
                "presentations": ("public.presentation", "presentations"), "spreadsheet": ("public.spreadsheet", "spreadsheets"),
                "spreadsheets": ("public.spreadsheet", "spreadsheets"), "document": ("public.content", "documents"),
                "documents": ("public.content", "documents"), "doc": ("public.content", "documents"),
                "font": ("public.font", "fonts"), "fonts": ("public.font", "fonts"),
            ]
            // A kind Spotlight has no type for narrows nothing (rather than becoming a name to look for).
            guard let (type, label) = types[value.lowercased()] else {
                var none = Condition(attributes: [], test: .equals(""), label: "")
                none.isKind = true
                return none
            }
            var condition = Condition(attributes: ["kMDItemContentTypeTree"], test: .equals(type), label: label)
            condition.isKind = true
            return condition
        default:
            return nil
        }
    }

    /// ">1920", ">=5", "<10m", "1h", "1,5" (a number, optionally with one of `units`) as a comparison.
    private static func comparison(_ text: String, units: [String: Double]) -> (Condition.Comparison, Double)? {
        var rest = Substring(text.lowercased())
        var comparison = Condition.Comparison.equal
        for candidate in [Condition.Comparison.greaterOrEqual, .lessOrEqual, .greater, .less] where rest.hasPrefix(candidate.rawValue) {
            comparison = candidate
            rest = rest.dropFirst(candidate.rawValue.count)
            break
        }
        if comparison == .equal, rest.hasPrefix("=") { rest = rest.dropFirst() }
        let digits = String(rest.prefix { $0.isNumber || $0 == "." || $0 == "," })
        // "1,920" is a thousand-separated number; "1,5" a decimal comma.
        let thousands = digits.range(of: #"^\d{1,3}(,\d{3})+$"#, options: .regularExpression) != nil
        let plain = thousands ? digits.replacingOccurrences(of: ",", with: "") : digits.replacingOccurrences(of: ",", with: ".")
        guard let number = Double(plain), number.isFinite, number >= 0 else { return nil }
        let unit = rest.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        if unit.isEmpty || unit == "px" { return (comparison, number) }
        guard let factor = units[unit] else { return nil }
        return (comparison, number * factor)
    }

    /// "10 min", "1 hr, 30 min", "45 sec".
    private static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "\(Int(seconds)) s"
    }

    private static func describe(_ comparison: Condition.Comparison) -> String {
        switch comparison {
        case .greater: "over"
        case .greaterOrEqual: "at least"
        case .less: "under"
        case .lessOrEqual: "at most"
        case .equal: "exactly"
        }
    }

    /// Plain-English searches that mean metadata ("photos taken with iPhone", "videos longer than 10 minutes", "pdfs
    /// with more than 20 pages", "songs by Miles Davis") as the same search in syntax; nil for anything else.
    static func naturalForm(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let quote = { (raw: String) in
            let value = raw.count > 1 && raw.hasPrefix("\"") && raw.hasSuffix("\"") ? String(raw.dropFirst().dropLast()) : raw
            return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func match(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$", options: [.caseInsensitive]),
                  let found = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else { return nil }
            return (0..<found.numberOfRanges).map { index in
                Range(found.range(at: index), in: trimmed).map { String(trimmed[$0]) } ?? ""
            }
        }
        // "taken with" or "shot on" a camera (not "photos on desktop", "pictures by date", "taken on June 3").
        let notCameras: Set<String> = ["desktop", "date", "name", "size", "kind", "the", "this", "last", "my", "today", "yesterday",
                                       "mac", "disk", "drive", "screen", "folder"]
        let months = DateFormatter().monthSymbols.map { $0.lowercased() } + DateFormatter().shortMonthSymbols.map { $0.lowercased() }
        func isCamera(_ text: String) -> Bool {
            let first = text.lowercased().split(separator: " ").first.map(String.init) ?? ""
            return !first.isEmpty && !notCameras.contains(first) && !months.contains(first) && first.first?.isNumber != true
        }
        if let parts = match(#"(?:photos?|pictures?|images?|pics?)\s+(?:taken|shot)\s+(?:with|on|by)\s+(?:an?\s+|my\s+)?(.+)"#),
           isCamera(parts[1]) {
            return "kind:image camera:" + quote(parts[1])
        }
        if let parts = match(#"(videos?|movies?|songs?|audio|music)\s+(longer|more|over|shorter|less|under)\s+(?:than\s+)?(\d+(?:[.,]\d+)?)\s*([a-z]+)"#) {
            let kind = ["video", "videos", "movie", "movies"].contains(parts[1].lowercased()) ? "video" : "audio"
            let op = ["longer", "more", "over"].contains(parts[2].lowercased()) ? ">" : "<"
            return "kind:\(kind) duration:\(op)\(parts[3])\(parts[4].lowercased())"
        }
        if let parts = match(#"(?:pdfs?|documents?)\s+(?:with\s+)?(more|over|fewer|less|under)\s+(?:than\s+)?(\d+)\s+pages?"#) {
            let op = ["more", "over"].contains(parts[1].lowercased()) ? ">" : "<"
            return "kind:pdf pages:\(op)\(parts[2])"
        }
        let notArtists: Set<String> = ["year", "date", "name", "size", "length", "genre", "album", "artist", "kind"]
        if let parts = match(#"(?:songs?|music|tracks?|albums?)\s+by\s+(.+)"#), !notArtists.contains(parts[1].lowercased()) {
            return "kind:audio artist:" + quote(parts[1])
        }
        return nil
    }

    /// Every condition at once. Values are passed as arguments, never pasted into the format.
    var predicate: NSPredicate {
        var parts = tags.map { NSPredicate(format: "%K ==[c] %@", "kMDItemUserTags", $0) }
        parts += words.map { NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, $0) }
        if !extensions.isEmpty {
            parts.append(Self.any(extensions.map { NSPredicate(format: "%K ENDSWITH[c] %@", NSMetadataItemFSNameKey, "." + $0) }))
        }
        for condition in conditions where !condition.attributes.isEmpty {
            parts.append(Self.any(condition.attributes.map { attribute in
                switch condition.test {
                case .contains(let text): NSPredicate(format: "%K CONTAINS[cd] %@", attribute, text)
                case .equals(let value): NSPredicate(format: "%K == %@", attribute, value)
                case .compare(let comparison, let number):
                    NSPredicate(format: "%K \(comparison.rawValue) %@", attribute, NSNumber(value: number))
                }
            }))
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

    /// "Tagged “Red” · images · camera “iPhone” · named “report” · .pdf", for the results summary.
    var summary: String {
        var parts: [String] = []
        if !tags.isEmpty { parts.append("Tagged " + ListFormatter.localizedString(byJoining: tags.map { "“\($0)”" })) }
        parts += conditions.map(\.label).filter { !$0.isEmpty }
        if !words.isEmpty { parts.append("named " + ListFormatter.localizedString(byJoining: words.map { "“\($0)”" })) }
        if !extensions.isEmpty { parts.append(extensions.map { "." + $0 }.joined(separator: ", ")) }
        guard let first = parts.first else { return "" }
        parts[0] = first.prefix(1).uppercased() + first.dropFirst()
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
