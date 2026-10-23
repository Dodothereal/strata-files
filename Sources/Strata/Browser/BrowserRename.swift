import AppKit

/// Owns name validation and the native extension confirmation. It receives the original item and a captured commit;
/// it never reads a browser's current selection or redirects a sheet into another pane.
enum BrowserRename {
    typealias Confirmation = @MainActor (URL, String, NSWindow?, @escaping (String) -> Void) -> Void

    enum Decision: Equatable {
        case unchanged, invalidName, hiddenName, rename
        case extensionChange(old: String, new: String)
    }

    static func decision(oldName: String, newName: String, isFolder: Bool) -> Decision {
        guard !newName.isEmpty, newName != oldName else { return .unchanged }
        if newName.contains("/") { return .invalidName }
        if newName.hasPrefix("."), !oldName.hasPrefix(".") { return .hiddenName }
        let oldExtension = (oldName as NSString).pathExtension
        let newExtension = (newName as NSString).pathExtension
        if !isFolder, oldExtension.lowercased() != newExtension.lowercased() {
            return .extensionChange(old: oldExtension, new: newExtension)
        }
        return .rename
    }

    static func confirmedName(_ response: NSApplication.ModalResponse, proposed newName: String,
                              oldExtension: String) -> String? {
        switch response {
        case .alertSecondButtonReturn:
            return newName
        case .alertFirstButtonReturn:
            // A final dot is an empty extension's delimiter. Earlier dots belong to the name and stay as typed.
            let stem = newName.hasSuffix(".") ? String(newName.dropLast()) : (newName as NSString).deletingPathExtension
            return oldExtension.isEmpty ? stem : "\(stem).\(oldExtension)"
        default:
            return nil
        }
    }

    /// Renames with Finder's checks: no "/" or leading dot, and a confirmation when a file's extension changes.
    static func confirm(_ url: URL, to newName: String, in window: NSWindow?, commit: @escaping (String) -> Void) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let isFolder = values?.isDirectory == true && values?.isPackage != true
        let oldExtension: String, newExtension: String
        switch decision(oldName: url.lastPathComponent, newName: newName, isFolder: isFolder) {
        case .unchanged:
            return
        case .invalidName:
            refuse(String(localized: "The name “\(newName)” can’t be used."),
                   String(localized: "Names can’t contain “/”. Try a different name."), in: window)
            return
        case .hiddenName:
            refuse(String(localized: "You can’t use a name that begins with a dot “.”."),
                   String(localized: "These names are reserved for the system, and the item would be hidden. Please choose another name."), in: window)
            return
        case .rename:
            commit(newName)
            return
        case .extensionChange(let old, let new):
            oldExtension = old
            newExtension = new
        }
        guard let window else { return }
        let alert = NSAlert()
        if oldExtension.isEmpty {
            alert.messageText = String(localized: "Are you sure you want to add the extension “.\(newExtension)” to the end of the name?")
        } else if newExtension.isEmpty {
            alert.messageText = String(localized: "Are you sure you want to remove the extension “.\(oldExtension)”?")
        } else {
            alert.messageText = String(localized: "Are you sure you want to change the extension from “.\(oldExtension)” to “.\(newExtension)”?")
        }
        alert.informativeText = String(localized: "If you make this change, your document may open in a different app.")
        alert.addButton(withTitle: oldExtension.isEmpty ? String(localized: "Don’t Add", comment: "Alert button: don’t add the file extension")
                                                        : String(localized: "Keep .\(oldExtension)", comment: "Alert button: keep the file extension (“Keep .txt”)"))
        alert.addButton(withTitle: newExtension.isEmpty ? String(localized: "Remove", comment: "Alert button: remove the file extension")
                                                        : String(localized: "Use .\(newExtension)", comment: "Alert button: use the new file extension (“Use .md”)"))
        alert.beginSheetModal(for: window) { [weak window] response in
            guard window != nil else { return }
            guard let name = confirmedName(response, proposed: newName, oldExtension: oldExtension) else { return }
            commit(name)
        }
    }

    private static func refuse(_ message: String, _ detail: String, in window: NSWindow?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }
}
