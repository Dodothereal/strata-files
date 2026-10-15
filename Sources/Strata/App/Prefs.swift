import AppKit

extension Notification.Name {
    static let prefsChanged = Notification.Name("StrataPrefsChanged")
    /// Theme, density or text size changed (Settings ▸ Appearance): views restyle, nothing reloads.
    static let appearanceChanged = Notification.Name("StrataAppearanceChanged")
    static let favoritesChanged = Notification.Name("StrataFavoritesChanged")
}

enum Prefs {
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let showHidden = "showHiddenFiles"
        static let foldersFirst = "foldersFirst"
        static let lastLocation = "lastLocation"
        static let returnOpens = "returnOpens"
        static let terminal = "terminalApp"
        static let newWindowsAtHome = "newWindowsAtHome"
        static let viewMode = "viewMode"
        static let gridIconSize = "gridIconSize"
        static let verifyCopies = "verifyCopies"
        static let favoritePaths = "favoritePaths"
        static let reopenWindows = "reopenWindows"
        static let openArchivesAsFolders = "openArchivesAsFolders"
        static let theme = "theme"
        static let density = "density"
        static let nameTextSize = "nameTextSize"
        static let showIconPreviews = "showIconPreviews"
        static let sidebarShowsTree = "sidebarShowsTree"
    }

    static func register() {
        defaults.register(defaults: [Key.showHidden: false, Key.foldersFirst: true, Key.gridIconSize: 72.0])
    }

    static var showHidden: Bool {
        get { defaults.bool(forKey: Key.showHidden) }
        set { defaults.set(newValue, forKey: Key.showHidden); NotificationCenter.default.post(name: .prefsChanged, object: nil) }
    }

    /// The sidebar shows the folder tree instead of Favorites, Locations and the rest.
    static var sidebarShowsTree: Bool {
        get { defaults.bool(forKey: Key.sidebarShowsTree) }
        set { defaults.set(newValue, forKey: Key.sidebarShowsTree); NotificationCenter.default.post(name: .prefsChanged, object: nil) }
    }

    static var foldersFirst: Bool {
        get { defaults.bool(forKey: Key.foldersFirst) }
        set { defaults.set(newValue, forKey: Key.foldersFirst); NotificationCenter.default.post(name: .prefsChanged, object: nil) }
    }

    /// Return opens the selection instead of renaming it (Finder renames).
    static var returnOpens: Bool {
        get { defaults.bool(forKey: Key.returnOpens) }
        set { defaults.set(newValue, forKey: Key.returnOpens) }
    }

    /// Bundle id of the terminal for "Open in Terminal"; nil picks the first installed of Ghostty, iTerm, Warp, Terminal.
    static var terminal: String? {
        get { defaults.string(forKey: Key.terminal) }
        set { defaults.set(newValue, forKey: Key.terminal) }
    }

    static var viewMode: Int {
        get { defaults.integer(forKey: Key.viewMode) }
        set { defaults.set(newValue, forKey: Key.viewMode) }
    }

    static var gridIconSize: Double {
        get { defaults.double(forKey: Key.gridIconSize) }
        set { defaults.set(newValue, forKey: Key.gridIconSize) }
    }

    /// The sidebar's favorite folders once you've changed them (nil: the defaults).
    static var favoritePaths: [String]? {
        get { defaults.stringArray(forKey: Key.favoritePaths) }
        set {
            defaults.set(newValue, forKey: Key.favoritePaths)
            NotificationCenter.default.post(name: .favoritesChanged, object: nil)
        }
    }

    /// Open the windows and tabs of the last session at launch.
    static var reopenWindows: Bool {
        get { defaults.object(forKey: Key.reopenWindows) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.reopenWindows) }
    }

    /// Opening a zip (or another archive) shows what's inside, like a folder, instead of unpacking it.
    static var openArchivesAsFolders: Bool {
        get { defaults.object(forKey: Key.openArchivesAsFolders) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.openArchivesAsFolders) }
    }

    /// 0 follows the system, 1 is always light, 2 always dark.
    static var theme: Int {
        get { defaults.integer(forKey: Key.theme) }
        set { defaults.set(newValue, forKey: Key.theme); NotificationCenter.default.post(name: .appearanceChanged, object: nil) }
    }

    /// Row spacing in the list and columns: 0 compact, 1 regular, 2 spacious.
    static var density: Int {
        get { defaults.object(forKey: Key.density) as? Int ?? 1 }
        set { defaults.set(newValue, forKey: Key.density); NotificationCenter.default.post(name: .appearanceChanged, object: nil) }
    }

    /// File names' text size in points (11–16).
    static var nameTextSize: Double {
        get { min(max(defaults.object(forKey: Key.nameTextSize) as? Double ?? 13, 11), 16) }
        set { defaults.set(newValue, forKey: Key.nameTextSize); NotificationCenter.default.post(name: .appearanceChanged, object: nil) }
    }

    /// Files show a Quick Look thumbnail of their contents in place of their icon, like Finder's "Show icon preview".
    static var showIconPreviews: Bool {
        get { defaults.object(forKey: Key.showIconPreviews) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showIconPreviews); NotificationCenter.default.post(name: .appearanceChanged, object: nil) }
    }

    /// Read every copied file back and compare it with the original (slower; catches failing disks and cables).
    static var verifyCopies: Bool {
        get { defaults.bool(forKey: Key.verifyCopies) }
        set { defaults.set(newValue, forKey: Key.verifyCopies) }
    }

    static var newWindowsAtHome: Bool {
        get { defaults.bool(forKey: Key.newWindowsAtHome) }
        set { defaults.set(newValue, forKey: Key.newWindowsAtHome) }
    }

    static let terminals: [(name: String, bundleID: String)] = [
        ("Ghostty", "com.mitchellh.ghostty"), ("iTerm", "com.googlecode.iterm2"), ("Warp", "dev.warp.Warp-Stable"),
        ("Terminal", "com.apple.Terminal"),
    ]

    static var terminalURL: URL? {
        let ids = (terminal.map { [$0] } ?? []) + terminals.map(\.bundleID)
        return ids.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    static var lastLocation: URL? {
        get { defaults.string(forKey: Key.lastLocation).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { defaults.set(newValue?.path, forKey: Key.lastLocation) }
    }
}
