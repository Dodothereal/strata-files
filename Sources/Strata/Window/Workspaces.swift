import AppKit

/// A named set of tabs, each with one or two pane folders, reopened as a window.
nonisolated struct Workspace: Codable, Equatable, Sendable {
    var name: String
    var tabs: [[String]]
}

enum Workspaces {
    private static let key = "workspaces"

    static var all: [Workspace] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([Workspace].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    /// Asks for a name and saves every tab of `window` (and its panes).
    static func saveCurrent(from window: NSWindow) {
        let windows = window.tabbedWindows ?? [window]
        let tabs = windows.compactMap { ($0.windowController as? BrowserWindowController)?.snapshot }
        guard !tabs.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "Save Workspace")
        alert.informativeText = String(localized: "Saves \(tabs.count) tabs and their panes, to reopen together from Window ▸ Workspaces.", comment: "plural")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = String(localized: "Name", comment: "Placeholder: the new workspace's name")
        field.stringValue = URL(fileURLWithPath: tabs[0][0]).lastPathComponent
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Save", comment: "Button: save the workspace"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                let name = field.stringValue.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                var saved = all.filter { $0.name != name }
                saved.append(Workspace(name: name, tabs: tabs))
                all = saved.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
    }
}
