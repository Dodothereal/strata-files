import AppKit

/// Rebuilt when the Dock asks, so favorite folders follow the sidebar without needing a browser window.
final class DockMenu {
    private let favorites: @MainActor () -> [Place]
    private let newWindow: @MainActor () -> Void
    private let recents: @MainActor () -> Void
    private let openFolder: @MainActor (URL) -> Void
    private var actions: [Action] = []

    init(favorites: @escaping @MainActor () -> [Place], newWindow: @escaping @MainActor () -> Void,
         recents: @escaping @MainActor () -> Void, openFolder: @escaping @MainActor (URL) -> Void) {
        self.favorites = favorites
        self.newWindow = newWindow
        self.recents = recents
        self.openFolder = openFolder
    }

    func build() -> NSMenu {
        actions.removeAll()
        let menu = NSMenu()
        menu.addItem(item(String(localized: "New Window"), symbol: "macwindow.badge.plus", perform: newWindow))
        menu.addItem(item(String(localized: "Recents"), symbol: "clock", perform: recents))

        let places = favorites()
        if !places.isEmpty {
            menu.addItem(.separator())
            let title = String(localized: "Favorites", comment: "Sidebar section title")
            let favoritesItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            favoritesItem.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
            let submenu = NSMenu(title: title)
            for place in places {
                let entry = item(place.title, symbol: place.symbol) { [openFolder] in openFolder(place.url) }
                entry.toolTip = place.url.path
                submenu.addItem(entry)
            }
            favoritesItem.submenu = submenu
            menu.addItem(favoritesItem)
        }
        MenuImages.show(in: menu)
        return menu
    }

    private func item(_ title: String, symbol: String, perform: @escaping @MainActor () -> Void) -> NSMenuItem {
        let action = Action(perform)
        actions.append(action)
        let item = NSMenuItem(title: title, action: #selector(Action.run(_:)), keyEquivalent: "")
        item.target = action
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    // The Dock sends actions with a nil sender, so each target keeps its own command and folder URL. NSMenuItem's
    // target is weak: the builder keeps these alive until the Dock asks for its next menu.
    private final class Action: NSObject {
        private let perform: @MainActor () -> Void

        init(_ perform: @escaping @MainActor () -> Void) { self.perform = perform }

        @objc func run(_ sender: Any?) { perform() }
    }
}
