import Foundation

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    static func bytes(_ n: Int64) -> String { byteFormatter.string(fromByteCount: n) }
    static func date(_ d: Date?) -> String { d.map(shortDate.string(from:)) ?? "—" }
    static func longDate(_ d: Date?) -> String { d.map(longDate.string(from:)) ?? "—" }

    static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n.formatted()) \(n == 1 ? singular : plural)"
    }

    /// Path with the home folder shortened to `~`.
    static func tildePath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
