import AppKit

extension Notification.Name {
    static let prefsChanged = Notification.Name("StrataPrefsChanged")
    /// Theme, density or text size changed (Settings ▸ Appearance): views restyle, nothing reloads.
    static let appearanceChanged = Notification.Name("StrataAppearanceChanged")
    /// Palette or window tint changed: redraw without reloading file views.
    static let colorThemeChanged = Notification.Name("StrataColorThemeChanged")
    static let favoritesChanged = Notification.Name("StrataFavoritesChanged")
    /// A list column was shown or hidden (right-click the column titles): every list follows.
    static let listColumnsChanged = Notification.Name("StrataListColumnsChanged")
    static let viewOptionsChanged = Notification.Name("StrataViewOptionsChanged")
    /// A sidebar section was hidden or shown: every window's sidebar follows.
    static let sidebarSectionsCollapsed = Notification.Name("StrataSidebarSectionsCollapsed")
}

/// Typed app settings. Production shares one instance; independent environments supply their own defaults and
/// notification center, so changing a fixture never reloads another environment's views.
final class Prefs {
    private static var selected: Prefs?
    nonisolated private static let testDomain = "dev.strata.tests.\(UUID().uuidString)"

    static func useApplicationPreferences() {
        precondition(selected == nil, "Configure preferences before creating app services")
        selected = Prefs(defaults: .standard, domainName: Bundle.main.bundleIdentifier ?? "dev.strata.app",
                         notifications: .default)
    }

    static var shared: Prefs {
        if let selected { return selected }
        guard let defaults = UserDefaults(suiteName: testDomain) else {
            preconditionFailure("Unable to create isolated test preferences")
        }
        let made = Prefs(defaults: defaults, domainName: testDomain, notifications: .default)
        selected = made
        registerTestCleanup()
        return made
    }

    private nonisolated static func registerTestCleanup() {
        // The test runner can exit from a worker thread; a C exit callback must not inherit MainActor isolation.
        atexit { UserDefaults.standard.removePersistentDomain(forName: Prefs.testDomain) }
    }

    let defaults: UserDefaults
    let domainName: String
    let notifications: NotificationCenter

    init(defaults: UserDefaults, domainName: String, notifications: NotificationCenter = NotificationCenter()) {
        self.defaults = defaults
        self.domainName = domainName
        self.notifications = notifications
    }

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
        static let sortColumn = "sortColumn"
        static let sortAscending = "sortAscending"
        static let hiddenListColumns = "hiddenListColumns"
        static let knownListColumns = "knownListColumns"
        static let dockSearch = "dockSearch"
        static let collapsedSidebarSections = "collapsedSidebarSections"
        static let newFileExtension = "newFileExtension"
    }

    /// An explicit app-language override. An empty value lets macOS choose the language on the next launch.
    var language: String {
        get { (defaults.persistentDomain(forName: domainName)?["AppleLanguages"] as? [String])?.first ?? "" }
        set {
            if newValue.isEmpty { defaults.removeObject(forKey: "AppleLanguages") }
            else { defaults.set([newValue], forKey: "AppleLanguages") }
        }
    }

    var showHidden: Bool {
        get { defaults.bool(forKey: Key.showHidden) }
        set { defaults.set(newValue, forKey: Key.showHidden); notifications.post(name: .prefsChanged, object: nil) }
    }

    /// The sidebar shows the folder tree instead of Favorites, Locations and the rest.
    var sidebarShowsTree: Bool {
        get { defaults.bool(forKey: Key.sidebarShowsTree) }
        set { defaults.set(newValue, forKey: Key.sidebarShowsTree); notifications.post(name: .prefsChanged, object: nil) }
    }

    /// Sidebar sections you've hidden (Hide on a section's title), by ID: they stay hidden until you show them again.
    var collapsedSidebarSections: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.collapsedSidebarSections) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.collapsedSidebarSections) }
    }

    /// The extension File ▸ New File gives the file ("txt" until you change it; empty for none).
    var newFileExtension: String {
        get { defaults.string(forKey: Key.newFileExtension).flatMap(FileOps.newFileExtension) ?? "txt" }
        set {
            guard let clean = FileOps.newFileExtension(newValue) else { return }
            defaults.set(clean, forKey: Key.newFileExtension)
        }
    }

    var foldersFirst: Bool {
        get { defaults.object(forKey: Key.foldersFirst) == nil ? true : defaults.bool(forKey: Key.foldersFirst) }
        set { defaults.set(newValue, forKey: Key.foldersFirst); notifications.post(name: .prefsChanged, object: nil) }
    }

    /// Return opens the selection instead of renaming it (Finder renames).
    var returnOpens: Bool {
        get { defaults.bool(forKey: Key.returnOpens) }
        set { defaults.set(newValue, forKey: Key.returnOpens) }
    }

    /// Bundle id of the terminal for "Open in Terminal"; nil picks the first installed of Ghostty, iTerm, Warp, Terminal.
    var terminal: String? {
        get { defaults.string(forKey: Key.terminal) }
        set { defaults.set(newValue, forKey: Key.terminal) }
    }

    var viewMode: Int {
        get { defaults.integer(forKey: Key.viewMode) }
        set { defaults.set(newValue, forKey: Key.viewMode) }
    }

    var gridIconSize: Double {
        get { defaults.object(forKey: Key.gridIconSize) == nil ? 72 : defaults.double(forKey: Key.gridIconSize) }
        set {
            defaults.set(newValue, forKey: Key.gridIconSize)
            notifications.post(name: .viewOptionsChanged, object: nil)
        }
    }

    var iconViewOptions: IconViewOptions {
        get { IconViewOptions.read(from: defaults) }
        set {
            newValue.save(in: defaults)
            notifications.post(name: .viewOptionsChanged, object: nil)
        }
    }

    /// The sidebar's favorite folders once you've changed them (nil: the defaults).
    var favoritePaths: [String]? {
        get { defaults.stringArray(forKey: Key.favoritePaths) }
        set {
            defaults.set(newValue, forKey: Key.favoritePaths)
            notifications.post(name: .favoritesChanged, object: nil)
        }
    }

    /// Open the windows and tabs of the last session at launch.
    var reopenWindows: Bool {
        get { defaults.object(forKey: Key.reopenWindows) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.reopenWindows) }
    }

    /// Opening a zip (or another archive) shows what's inside, like a folder, instead of unpacking it.
    var openArchivesAsFolders: Bool {
        get { defaults.object(forKey: Key.openArchivesAsFolders) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.openArchivesAsFolders) }
    }

    /// 0 follows the system, 1 is always light, 2 always dark.
    var theme: Int {
        get { defaults.integer(forKey: Key.theme) }
        set { defaults.set(newValue, forKey: Key.theme); notifications.post(name: .appearanceChanged, object: nil) }
    }

    var colorThemeOptions: ColorThemeOptions {
        get { ColorThemeOptions.read(from: defaults) }
        set {
            guard newValue != colorThemeOptions else { return }
            newValue.save(in: defaults)
            notifications.post(name: .colorThemeChanged, object: nil)
        }
    }

    /// Row spacing in the list and columns: 0 compact, 1 regular, 2 spacious.
    var density: Int {
        get { defaults.object(forKey: Key.density) as? Int ?? 1 }
        set { defaults.set(newValue, forKey: Key.density); notifications.post(name: .appearanceChanged, object: nil) }
    }

    /// File names' text size in points (11–16).
    var nameTextSize: Double {
        get { min(max(defaults.object(forKey: Key.nameTextSize) as? Double ?? 13, 11), 16) }
        set { defaults.set(newValue, forKey: Key.nameTextSize); notifications.post(name: .appearanceChanged, object: nil) }
    }

    /// Files show a Quick Look thumbnail of their contents in place of their icon, like Finder's "Show icon preview".
    var showIconPreviews: Bool {
        get { defaults.object(forKey: Key.showIconPreviews) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showIconPreviews); notifications.post(name: .appearanceChanged, object: nil) }
    }

    /// Read every copied file back and compare it with the original (slower; catches failing disks and cables).
    var verifyCopies: Bool {
        get { defaults.bool(forKey: Key.verifyCopies) }
        set { defaults.set(newValue, forKey: Key.verifyCopies) }
    }

    var newWindowsAtHome: Bool {
        get { defaults.bool(forKey: Key.newWindowsAtHome) }
        set { defaults.set(newValue, forKey: Key.newWindowsAtHome) }
    }

    let terminals: [(name: String, bundleID: String)] = [
        ("Ghostty", "com.mitchellh.ghostty"), ("iTerm", "com.googlecode.iterm2"), ("Warp", "dev.warp.Warp-Stable"),
        ("Terminal", "com.apple.Terminal"),
    ]

    var terminalURL: URL? {
        let ids = (terminal.map { [$0] } ?? []) + terminals.map(\.bundleID)
        return ids.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    /// List sort from the last session. Unknown or missing values are Name, ascending.
    var sortColumn: String {
        get {
            let stored = defaults.string(forKey: Key.sortColumn) ?? SortKey.name.rawValue
            return SortKey(rawValue: stored)?.rawValue ?? SortKey.name.rawValue
        }
        set { defaults.set(newValue, forKey: Key.sortColumn) }
    }

    var sortAscending: Bool {
        get { defaults.object(forKey: Key.sortAscending) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.sortAscending) }
    }

    /// Settings ▸ General ▸ Search box in the Dock (see `DockSearch`). Off until you turn it on.
    var dockSearch: Bool {
        get { defaults.bool(forKey: Key.dockSearch) }
        set { defaults.set(newValue, forKey: Key.dockSearch) }
    }

    /// The list columns you've hidden, by identifier. Date Created starts hidden, as in Finder.
    var hiddenListColumns: Set<String> {
        get { ListColumn.hidden(stored: defaults.stringArray(forKey: Key.hiddenListColumns),
                                known: defaults.stringArray(forKey: Key.knownListColumns)) }
        set {
            defaults.set(newValue.sorted(), forKey: Key.hiddenListColumns)
            defaults.set(ListColumn.allCases.map(\.rawValue), forKey: Key.knownListColumns)
            notifications.post(name: .listColumnsChanged, object: nil)
        }
    }

    var lastLocation: URL? {
        get { defaults.string(forKey: Key.lastLocation).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) } }
        set { defaults.set(newValue?.path, forKey: Key.lastLocation) }
    }
}
