import Foundation

/// `value` as Int64, clamped to its range (a typed "size:9e30" or "1e20 days" must not trap); nil for NaN.
nonisolated func saturatingInt64(_ value: Double) -> Int64? {
    guard !value.isNaN else { return nil }
    if value >= 9.2e18 { return .max }
    if value <= -9.2e18 { return .min }
    return Int64(value)
}

/// A count of days, weeks… from a query, kept to a sane range (date arithmetic overflows on absurd values).
nonisolated func boundedCount(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    return Int(max(-1_000_000, min(1_000_000, value)))
}

/// Seconds since 1970 as the index's 32-bit timestamp, clamped.
nonisolated func indexStamp(_ date: Date) -> UInt32 {
    UInt32(clamping: saturatingInt64(date.timeIntervalSince1970) ?? 0)
}

/// A parsed search: plain words match names (all must appear), plus Everything-style filters:
/// `ext:pdf;png`, `*.pdf`, `kind:image|video|audio|doc|code|archive|app|folder|file`, `size:>100mb`, `size:1mb..1gb`,
/// `modified:today|yesterday|<7d|>30d|2026`, `in:~/Documents` or `in:github` (any enclosing folder name),
/// `!word` to exclude, `"exact phrase"`, and `a/b` to match a folder named like `a` above a name like `b`.
nonisolated struct IndexQuery: Sendable {
    enum Kind: String, Sendable {
        case folder, file, image, video, audio, document, code, archive, app
    }

    var terms: [[UInt8]] = []
    var excludedTerms: [[UInt8]] = []
    /// `a/b` terms: ancestors must match the leading parts, the name the last.
    var pathTerms: [[[UInt8]]] = []
    var extensions: Set<String> = []
    var kind: Kind?
    var minSize: Int64?
    var maxSize: Int64?
    var modifiedAfter: UInt32?
    var modifiedBefore: UInt32?
    var scopePath: String?
    var scopeNames: [[UInt8]] = []
    var includeNoise = false
    var includeHidden = false

    var isEmpty: Bool {
        terms.isEmpty && pathTerms.isEmpty && extensions.isEmpty && kind == nil && minSize == nil && maxSize == nil
            && modifiedAfter == nil && modifiedBefore == nil && scopeNames.isEmpty
    }

    static func parse(_ text: String, now: Date = .now) -> IndexQuery {
        var query = IndexQuery()
        for token in tokenize(text) {
            let lower = token.lowercased()
            if let value = value(of: lower, keys: ["ext:", "extension:"]) {
                query.extensions.formUnion(value.split(whereSeparator: { ";,|".contains($0) }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
            } else if lower.hasPrefix("*."), lower.count > 2, !lower.dropFirst(2).contains("*") {
                query.extensions.insert(String(lower.dropFirst(2)))
            } else if let value = value(of: lower, keys: ["kind:", "type:", "is:"]) {
                query.kind = kind(value)
            } else if let value = value(of: lower, keys: ["size:"]) {
                (query.minSize, query.maxSize) = sizeRange(value)
            } else if let value = value(of: lower, keys: ["modified:", "mod:", "date:", "dm:"]) {
                (query.modifiedAfter, query.modifiedBefore) = dateRange(value, now: now)
            } else if let value = value(of: token, keys: ["in:", "In:", "IN:"]) {
                if value.hasPrefix("/") || value.hasPrefix("~") {
                    query.scopePath = (value as NSString).expandingTildeInPath
                } else {
                    query.scopeNames.append(Array(value.lowercased().utf8))
                }
            } else if lower.hasPrefix("!") || (lower.hasPrefix("-") && lower.count > 1) {
                query.excludedTerms.append(Array(lower.dropFirst().utf8))
            } else if lower.contains("/") {
                let parts = lower.split(separator: "/").map { Array($0.utf8) }
                if parts.count == 1 { query.terms.append(parts[0]) } else if parts.count > 1 { query.pathTerms.append(parts) }
            } else if !lower.isEmpty {
                query.terms.append(Array(lower.utf8))
            }
        }
        let mentioned = (query.terms + query.pathTerms.flatMap { $0 } + query.scopeNames).map { String(decoding: $0, as: UTF8.self) }
        query.includeHidden = mentioned.contains { $0.hasPrefix(".") }
        // `in:target` (or another build/cache folder name) means you want to look inside such folders.
        let scopes = query.scopeNames.map { String(decoding: $0, as: UTF8.self) }
        query.includeNoise = mentioned.contains { noiseWords.contains($0) || $0.hasPrefix(".") }
            || scopes.contains { buildFolderWords.contains($0) }
        return query
    }

    private static let noiseWords: Set<String> = ["library", "node_modules", "caches", "deriveddata", "pods", ".git"]
    private static let buildFolderWords: Set<String> = ["target", "dist", "build", "bin", "obj", "out", "coverage"]

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func value(of token: String, keys: [String]) -> String? {
        for key in keys where token.hasPrefix(key) && token.count > key.count {
            return String(token.dropFirst(key.count))
        }
        return nil
    }

    private static func kind(_ value: String) -> Kind? {
        switch value {
        case "folder", "folders", "dir", "directory": .folder
        case "file", "files": .file
        case "image", "images", "photo", "photos", "picture", "pic": .image
        case "video", "videos", "movie", "movies": .video
        case "audio", "music", "sound", "song": .audio
        case "doc", "docs", "document", "documents", "text": .document
        case "code", "source", "src": .code
        case "archive", "archives", "zip", "compressed": .archive
        case "app", "apps", "application", "applications": .app
        default: nil
        }
    }

    static func bytes(_ text: String) -> Int64? {
        let units: [(String, Double)] = [("tb", 1e12), ("gb", 1e9), ("mb", 1e6), ("kb", 1e3), ("t", 1e12), ("g", 1e9), ("m", 1e6), ("k", 1e3), ("b", 1)]
        for (suffix, multiplier) in units where text.hasSuffix(suffix) {
            guard let number = Double(text.dropLast(suffix.count)) else { return nil }
            return saturatingInt64(number * multiplier)
        }
        return Double(text).flatMap(saturatingInt64)
    }

    private static func sizeRange(_ value: String) -> (Int64?, Int64?) {
        if let range = value.range(of: "..") {
            return (bytes(String(value[..<range.lowerBound])), bytes(String(value[range.upperBound...])))
        }
        if value.hasPrefix(">=") { return (bytes(String(value.dropFirst(2))), nil) }
        if value.hasPrefix("<=") { return (nil, bytes(String(value.dropFirst(2)))) }
        if value.hasPrefix(">") { return (bytes(String(value.dropFirst())).map { $0 == .max ? .max : $0 + 1 }, nil) }
        if value.hasPrefix("<") { return (nil, bytes(String(value.dropFirst())).map { $0 == .min ? .min : $0 - 1 }) }
        switch value {
        case "empty": return (0, 0)
        case "tiny": return (0, 10_000)
        case "small": return (10_001, 1_000_000)
        case "medium": return (1_000_001, 100_000_000)
        case "large": return (100_000_001, 1_000_000_000)
        case "huge": return (1_000_000_001, nil)
        default:
            let exact = bytes(value)
            return (exact, exact)
        }
    }

    private static func dateRange(_ value: String, now: Date) -> (UInt32?, UInt32?) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func stamp(_ date: Date) -> UInt32 { indexStamp(date) }
        // Calendar days, not 86,400 s: a day around a daylight-saving change is 23 or 25 hours.
        func dayAfter(_ date: Date) -> Date { calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400) }
        switch value {
        case "today": return (stamp(today), nil)
        case "yesterday":
            return (stamp(calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)), stamp(today))
        case "thisweek", "week": return (stamp(now.addingTimeInterval(-7 * 86_400)), nil)
        case "thismonth", "month": return (stamp(now.addingTimeInterval(-30 * 86_400)), nil)
        default: break
        }
        if let operatorEnd = value.firstIndex(where: { !"<>=".contains($0) }), operatorEnd != value.startIndex {
            let op = value[..<operatorEnd]
            let amount = String(value[operatorEnd...])
            if let seconds = duration(amount) {
                let boundary = stamp(now.addingTimeInterval(-seconds))
                // `<7d` means "less than 7 days old"; `>30d` means "older than 30 days".
                return op.hasPrefix("<") ? (boundary, nil) : (nil, boundary)
            }
            if let date = day(amount) {
                return op.hasPrefix("<") ? (nil, stamp(date)) : (stamp(date), nil)
            }
        }
        if value.count == 4, let year = Int(value),
           let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
           let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) {
            return (stamp(start), stamp(end))
        }
        if let date = day(value) { return (stamp(date), stamp(dayAfter(date))) }
        return (nil, nil)
    }

    private static func duration(_ text: String) -> Double? {
        let units: [(Character, Double)] = [("h", 3600), ("d", 86_400), ("w", 7 * 86_400), ("m", 30 * 86_400), ("y", 365 * 86_400)]
        guard let last = text.last, let unit = units.first(where: { $0.0 == last }), let number = Double(text.dropLast()) else { return nil }
        return number * unit.1
    }

    private static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}

/// One search result, read out of the index under its lock.
nonisolated struct IndexHit: Sendable {
    let path: String
    let isDirectory: Bool
    let isPackage: Bool
    let size: Int64
    let files: UInt32
    let mtime: UInt32
    let score: Int
}

/// Per-chunk results collected from `concurrentPerform` workers.
nonisolated private final class Partials: @unchecked Sendable {
    private var chunks: [[(id: Int32, score: Int32)]]
    private let lock = NSLock()

    init(count: Int) { chunks = Array(repeating: [], count: count) }

    func set(_ index: Int, _ value: [(id: Int32, score: Int32)]) {
        lock.lock()
        chunks[index] = value
        lock.unlock()
    }

    var all: [(id: Int32, score: Int32)] { chunks.flatMap { $0 } }
}

nonisolated enum IndexSearch {
    private static let extensionsByKind: [IndexQuery.Kind: Set<String>] = [
        .image: ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "raw", "cr2", "cr3", "nef", "arw", "dng", "psd", "ico", "icns", "avif"],
        .video: ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg", "3gp"],
        .audio: ["mp3", "m4a", "wav", "aiff", "aif", "flac", "ogg", "aac", "opus", "wma", "caf"],
        .document: ["pdf", "doc", "docx", "pages", "txt", "rtf", "md", "markdown", "key", "ppt", "pptx", "xls", "xlsx", "numbers", "csv", "odt", "ods", "epub", "tex"],
        .code: ["swift", "rs", "ts", "tsx", "js", "jsx", "mjs", "py", "go", "c", "h", "cpp", "hpp", "cc", "m", "mm", "cs", "java", "kt", "rb", "php", "sh", "zsh", "json", "yaml", "yml", "toml", "html", "css", "scss", "xml", "sql", "gd", "lua", "dart", "vue", "svelte"],
        .archive: ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg", "iso", "zst"],
    ]

    static func extensions(for kind: IndexQuery.Kind) -> Set<String> {
        extensionsByKind[kind] ?? []
    }

    /// Runs `query` over the whole store in parallel and returns the best `limit` hits plus the total match count.
    static func run(_ query: IndexQuery, in store: IndexStore, limit: Int) -> (hits: [IndexHit], total: Int) {
        store.read {
            let count = store.count
            guard count > 0, !query.isEmpty else { return ([], 0) }
            let scopeID: Int32? = query.scopePath.flatMap { store.lookup($0) }
            if query.scopePath != nil && scopeID == nil { return ([], 0) }
            // Searching inside a cache or build folder (in:, or the scope bar while browsing it) includes its contents.
            var scoped = query
            if let scopeID, store.flags[Int(scopeID)] & IndexStore.Flag.noise != 0 { scoped.includeNoise = true }
            let query = scoped
            let extensions = query.kind.flatMap { extensionsByKind[$0] }.map { query.extensions.isEmpty ? $0 : $0.intersection(query.extensions) }
                ?? query.extensions
            let wantedExtensions = extensions.compactMap { ext in Array(ext.utf8).withUnsafeBufferPointer { packExtension($0) } }
            let now = Int(Date().timeIntervalSince1970)

            let chunks = max(1, min(64, count / 50_000))
            let partials = Partials(count: chunks)
            store.withColumns { columns in
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    let lower = count * chunk / chunks
                    let upper = count * (chunk + 1) / chunks
                    var found: [(id: Int32, score: Int32)] = []
                    for id in lower..<upper {
                        if let score = match(id, query, columns, scopeID, wantedExtensions, now) {
                            found.append((Int32(id), Int32(score)))
                        }
                    }
                    partials.set(chunk, found)
                }
            }
            var all = partials.all
            let total = all.count
            if all.count > limit {
                all.sort { $0.score > $1.score }
                all.removeSubrange(limit...)
            } else {
                all.sort { $0.score > $1.score }
            }
            let hits = all.map { item -> IndexHit in
                let id = Int(item.id)
                return IndexHit(path: store.path(of: item.id), isDirectory: store.flags[id] & IndexStore.Flag.directory != 0,
                                isPackage: store.flags[id] & IndexStore.Flag.package != 0, size: store.size[id],
                                files: store.fileCount[id], mtime: store.mtime[id], score: Int(item.score))
            }
            return (hits, total)
        }
    }

    /// Files changed recently, newest first, skipping folders, hidden items and noise such as caches.
    static func recent(in store: IndexStore, since: UInt32, limit: Int) -> [IndexHit] {
        store.read {
            var found: [(id: Int32, mtime: UInt32)] = []
            let skip = IndexStore.Flag.directory | IndexStore.Flag.noise | IndexStore.Flag.hidden | IndexStore.Flag.deleted
            // App internals carry the noise flag, so the skip mask already leaves them out.
            for id in 0..<store.count where store.flags[id] & skip == 0 && store.mtime[id] >= since {
                found.append((Int32(id), store.mtime[id]))
            }
            found.sort { $0.mtime > $1.mtime }
            return found.prefix(limit).map { item in
                let id = Int(item.id)
                return IndexHit(path: store.path(of: item.id), isDirectory: false, isPackage: false, size: store.size[id],
                                files: 1, mtime: store.mtime[id], score: 0)
            }
        }
    }

    // Called under the read lock from many threads at once.
    private static func match(_ i: Int, _ query: IndexQuery, _ c: IndexStore.Columns, _ scopeID: Int32?,
                              _ extensions: [UInt64], _ now: Int) -> Int? {
        let flags = c.flags[i]
        if flags & IndexStore.Flag.deleted != 0 || c.parent[i] < 0 { return nil }
        if !query.includeNoise && flags & IndexStore.Flag.noise != 0 { return nil }
        if !query.includeHidden && flags & IndexStore.Flag.hidden != 0 { return nil }
        let isDirectory = flags & IndexStore.Flag.directory != 0
        let isPackage = flags & IndexStore.Flag.package != 0
        switch query.kind {
        case .folder: if !isDirectory || isPackage { return nil }
        case .file: if isDirectory && !isPackage { return nil }
        case .app: if !isPackage { return nil }
        default: break
        }
        if let minSize = query.minSize, c.size[i] < minSize { return nil }
        if let maxSize = query.maxSize, c.size[i] > maxSize { return nil }
        if let after = query.modifiedAfter, c.mtime[i] < after { return nil }
        if let before = query.modifiedBefore, c.mtime[i] >= before { return nil }

        let name = c.name(i)
        if query.kind == .app {
            guard hasSuffix(name, appSuffix) else { return nil }
        } else if !extensions.isEmpty {
            guard !isDirectory || isPackage, let dot = name.lastIndex(of: UInt8(ascii: ".")) else { return nil }
            guard let ext = packExtension(UnsafeBufferPointer(rebasing: name[(dot + 1)...])), extensions.contains(ext) else { return nil }
        }
        var score = 0
        for (index, term) in query.terms.enumerated() {
            guard let position = find(term, in: name) else { return nil }
            score += index == 0 ? positionScore(position, term.count, name) : 10
        }
        for term in query.excludedTerms where find(term, in: name) != nil { return nil }
        for parts in query.pathTerms {
            guard let last = parts.last, let position = find(last, in: name) else { return nil }
            guard ancestorsMatch(parts.dropLast(), from: c.parent[i], c) else { return nil }
            score += positionScore(position, last.count, name) + 20
        }
        for scope in query.scopeNames {
            guard ancestorsMatch([scope][...], from: c.parent[i], c) else { return nil }
        }
        // Depth doubles as the scope check: walk to the root once.
        var depth = 0
        var inScope = scopeID == nil
        var ancestor = c.parent[i]
        while ancestor >= 0 {
            if ancestor == scopeID { inScope = true }
            depth += 1
            ancestor = c.parent[Int(ancestor)]
        }
        guard inScope else { return nil }
        // Prefer shallow paths, recent changes, apps and folders a little.
        score -= depth * 2 + name.count / 6
        let age = now - Int(c.mtime[i])
        if age < 86_400 { score += 12 } else if age < 7 * 86_400 { score += 8 } else if age < 30 * 86_400 { score += 4 }
        if isPackage { score += 10 } else if isDirectory { score += 4 }
        return score + 1000
    }

    private static let appSuffix = Array(".app".utf8)

    /// Lowercased extension packed into one integer (extensions longer than 8 bytes never match).
    @inline(__always)
    private static func packExtension(_ ext: UnsafeBufferPointer<UInt8>) -> UInt64? {
        guard !ext.isEmpty, ext.count <= 8 else { return nil }
        var packed: UInt64 = 0
        for byte in ext { packed = packed << 8 | UInt64(fold(byte)) }
        return packed
    }

    private static func positionScore(_ position: Int, _ termLength: Int, _ name: UnsafeBufferPointer<UInt8>) -> Int {
        if position == 0 && termLength == name.count { return 120 }
        if position == 0 { return 70 }
        let previous = name[position - 1]
        if previous == UInt8(ascii: " ") || previous == UInt8(ascii: "-") || previous == UInt8(ascii: "_") || previous == UInt8(ascii: ".") {
            return 45
        }
        return 20
    }

    /// Each part (in order, nearest last) must be found in some ancestor's name, walking up from `start`.
    private static func ancestorsMatch(_ parts: ArraySlice<[UInt8]>, from start: Int32, _ c: IndexStore.Columns) -> Bool {
        var remaining = parts
        var ancestor = start
        while let part = remaining.last {
            guard ancestor >= 0 else { return false }
            if find(part, in: c.name(Int(ancestor))) != nil { remaining.removeLast() }
            ancestor = c.parent[Int(ancestor)]
        }
        return true
    }

    @inline(__always)
    private static func fold(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte | 0x20 : byte
    }

    /// Case-insensitive (ASCII) substring search; `term` is already lowercase.
    private static func find(_ term: [UInt8], in name: UnsafeBufferPointer<UInt8>) -> Int? {
        let n = name.count, m = term.count
        guard m > 0, m <= n else { return m == 0 ? 0 : nil }
        let first = term[0]
        var i = 0
        while i <= n - m {
            if fold(name[i]) == first {
                var j = 1
                while j < m && fold(name[i + j]) == term[j] { j += 1 }
                if j == m { return i }
            }
            i += 1
        }
        return nil
    }

    private static func equalsFolded(_ a: UnsafeBufferPointer<UInt8>, _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        for k in 0..<a.count where fold(a[k]) != b[k] { return false }
        return true
    }

    private static func hasSuffix(_ name: UnsafeBufferPointer<UInt8>, _ suffix: [UInt8]) -> Bool {
        guard name.count >= suffix.count else { return false }
        return equalsFolded(UnsafeBufferPointer(rebasing: name[(name.count - suffix.count)...]), suffix)
    }
}
