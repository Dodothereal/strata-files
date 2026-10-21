import Foundation

/// Searches saved from the scope bar, shown in the sidebar.
nonisolated struct SavedSearch: Codable, Equatable, Sendable {
    var name: String
    var query: String
    var scopePath: String?
}

final class SavedSearches {
    private let key = "savedSearches"
    private let preferences: Prefs

    init(preferences: Prefs) { self.preferences = preferences }

    var all: [SavedSearch] {
        get {
            guard let data = preferences.defaults.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([SavedSearch].self, from: data)) ?? []
        }
        set {
            preferences.defaults.set(try? JSONEncoder().encode(newValue), forKey: key)
            preferences.notifications.post(name: .savedSearchesChanged, object: nil)
        }
    }

    /// Keep searches with the same title but different queries or scopes; only an exact duplicate is already saved.
    @discardableResult
    func save(_ search: SavedSearch) -> Bool {
        var searches = all
        guard !searches.contains(search) else { return false }
        searches.append(search)
        all = searches
        return true
    }

    func remove(_ search: SavedSearch) { all.removeAll { $0 == search } }
}

extension Notification.Name {
    static let savedSearchesChanged = Notification.Name("StrataSavedSearchesChanged")
}
