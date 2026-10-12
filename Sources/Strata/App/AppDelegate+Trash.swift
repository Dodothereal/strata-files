import AppKit

extension AppDelegate {
    /// Empties every Trash for good, after asking (Finder's ⇧⌘⌫). macOS guards the Trash, so this needs Full Disk Access.
    @objc func emptyTrash(_ sender: Any?) {
        let window = NSApp.keyWindow
        guard Privacy.hasFullDiskAccess else {
            let alert = NSAlert()
            alert.messageText = "Strata needs Full Disk Access to empty the Trash."
            alert.informativeText = "macOS protects the Trash. Turn on Strata in Privacy & Security ▸ Full Disk Access."
            alert.addButton(withTitle: "Open Privacy Settings")
            alert.addButton(withTitle: "Cancel")
            BrowserViewController.present(alert, in: window) { response in
                if response == .alertFirstButtonReturn { NSWorkspace.shared.open(Privacy.settingsURL) }
            }
            return
        }
        Task {
            let contents = await Trash.contents().filter { $0.count > 0 }
            let count = contents.reduce(0) { $0 + $1.count }
            let alert = NSAlert()
            guard count > 0 else {
                alert.messageText = "The Trash is empty."
                BrowserViewController.present(alert, in: window) { _ in }
                return
            }
            alert.messageText = count == 1
                ? "Permanently erase the item in the Trash?"
                : "Permanently erase the \(count.formatted()) items in the Trash?"
            // Other disks keep their own Trash; say what's on which.
            var info = ""
            if contents.count > 1 {
                info = ListFormatter.localizedString(byJoining: contents.map { "\($0.count.formatted()) on “\($0.disk)”" }) + ". "
            }
            alert.informativeText = info + "You can’t undo this action."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Empty Trash")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].hasDestructiveAction = true
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
            BrowserViewController.present(alert, in: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                Task {
                    let failures = await Trash.empty()
                    if failures.count < count {
                        Trash.emptySound?.stop()
                        Trash.emptySound?.play()
                    }
                    NotificationCenter.default.post(name: .trashChanged, object: nil)
                    if !failures.isEmpty { BrowserViewController.report(failures, title: "couldn’t be deleted", in: window) }
                }
            }
        }
    }
}
