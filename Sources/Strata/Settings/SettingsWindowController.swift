import AppKit
import SwiftUI

/// ⌘, — the standard toolbar-tabbed settings window, each pane a SwiftUI form.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func pane(_ title: String, _ symbol: String, _ view: some View) -> NSTabViewItem {
            let item = NSTabViewItem(viewController: NSHostingController(rootView: view.frame(width: 520)))
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return item
        }
        tabs.addTabViewItem(pane("General", "gearshape", GeneralSettings()))
        tabs.addTabViewItem(pane("Search & Index", "magnifyingglass", IndexSettings()))
        tabs.addTabViewItem(pane("Terminal", "terminal", TerminalSettings()))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = "Settings"
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
    }
}

/// Bridges a `Prefs` property into SwiftUI and refreshes when it changes.
private struct PrefToggle: View {
    let title: String
    let caption: String?
    let get: () -> Bool
    let set: (Bool) -> Void
    @State private var value = false

    var body: some View {
        Toggle(isOn: Binding(get: { value }, set: { value = $0; set($0) })) {
            Text(title)
            if let caption { Text(caption) }
        }
        .onAppear { value = get() }
    }
}

private struct GeneralSettings: View {
    @State private var returnOpens = Prefs.returnOpens
    @State private var atHome = Prefs.newWindowsAtHome
    @State private var isFileViewer = FileViewer.isStrata

    var body: some View {
        Form {
            Section("Browsing") {
                PrefToggle(title: "Show hidden files", caption: "Also ⇧⌘. in any window.",
                           get: { Prefs.showHidden }, set: { Prefs.showHidden = $0 })
                PrefToggle(title: "Keep folders on top", caption: nil,
                           get: { Prefs.foldersFirst }, set: { Prefs.foldersFirst = $0 })
                Picker("Return key", selection: Binding(get: { returnOpens }, set: { returnOpens = $0; Prefs.returnOpens = $0 })) {
                    Text("Renames the selection (like Finder)").tag(false)
                    Text("Opens the selection").tag(true)
                }
                Picker("New windows open", selection: Binding(get: { atHome }, set: { atHome = $0; Prefs.newWindowsAtHome = $0 })) {
                    Text("Where you left off").tag(false)
                    Text("Your home folder").tag(true)
                }
            }
            Section {
                Toggle(isOn: Binding(get: { isFileViewer }, set: { isFileViewer = $0; FileViewer.setStrata($0) })) {
                    Text("Open “Reveal in Finder” in Strata")
                    Text("Apps that show files in Finder (Show in Finder, Reveal) open Strata instead. Applies to apps launched after the change.")
                }
            } header: {
                Text("Default File Browser")
            }
            Section("Command Line") {
                LabeledContent("strata") {
                    Button("Install…") { CommandLineTool.install() }
                }
                Text("`strata .` opens the current folder; `strata -s \"ext:pdf invoice\"` searches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct IndexSettings: View {
    @State private var status = ""
    @State private var hasAccess = Privacy.hasFullDiskAccess
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Index") {
                LabeledContent("Status", value: status)
                LabeledContent("Covers", value: "Your home folder and Applications")
                LabeledContent("Rebuild") {
                    Button("Rebuild Index") { FileIndex.shared.rebuild() }
                }
            }
            Section {
                LabeledContent("Full Disk Access") {
                    if hasAccess {
                        Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open Privacy Settings…") { NSWorkspace.shared.open(Privacy.settingsURL) }
                    }
                }
                if !hasAccess {
                    Text("Without it, Desktop, Documents and Downloads are indexed only after you open them in Strata, and other apps’ data is skipped.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Access")
            }
            Section("Search Syntax") {
                syntax("invoice 2026", "names containing all words")
                syntax("ext:pdf;png  or  *.pdf", "file extensions")
                syntax("kind:image|video|audio|doc|code|archive|app|folder", "kind of item")
                syntax("size:>100mb  size:1mb..1gb", "size")
                syntax("modified:today  modified:<7d  modified:2026", "date modified")
                syntax("in:~/Documents  in:github", "inside a folder (path or name)")
                syntax("github/acme  !draft  \"exact phrase\"", "folder/name, exclude a word, phrase")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func syntax(_ example: String, _ meaning: String) -> some View {
        LabeledContent {
            Text(meaning).foregroundStyle(.secondary)
        } label: {
            Text(example).font(.system(.callout, design: .monospaced))
        }
    }

    private func refresh() {
        Privacy.refresh()
        hasAccess = Privacy.hasFullDiskAccess
        switch FileIndex.shared.phase {
        case .loading: status = "Loading…"
        case .scanning(let items): status = "Indexing… \(items.formatted()) items so far"
        case .ready: status = "\(FileIndex.shared.itemCount.formatted()) items · kept current live"
        }
    }
}

private struct TerminalSettings: View {
    @State private var selection = Prefs.terminal ?? ""

    var body: some View {
        Form {
            Picker("Open in Terminal uses", selection: Binding(get: { selection }, set: { selection = $0; Prefs.terminal = $0.isEmpty ? nil : $0 })) {
                Text("Automatic").tag("")
                ForEach(Prefs.terminals.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil },
                        id: \.bundleID) { terminal in
                    Text(terminal.name).tag(terminal.bundleID)
                }
            }
            Text("Automatic picks the first installed of Ghostty, iTerm, Warp and Terminal. ⌃⌘T opens the current folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The system-wide "file viewer" that `NSWorkspace.activateFileViewerSelecting` (Reveal in Finder) talks to.
enum FileViewer {
    private static let key = "NSFileViewer"

    static var isStrata: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? String == Bundle.main.bundleIdentifier
    }

    static func setStrata(_ on: Bool) {
        var global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        if on { global[key] = Bundle.main.bundleIdentifier } else { global.removeValue(forKey: key) }
        UserDefaults.standard.setPersistentDomain(global, forName: UserDefaults.globalDomain)
    }
}

/// Installs the `strata` command (shipped inside the app) by linking it into /usr/local/bin.
enum CommandLineTool {
    static func install() {
        let tool = Bundle.main.bundleURL.appending(path: "Contents/Helpers/strata").path
        let link = "/usr/local/bin/strata"
        let alert = NSAlert()
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == tool {
            alert.messageText = "The strata command is already installed."
        } else if FileManager.default.isWritableFile(atPath: "/usr/local/bin") {
            try? FileManager.default.removeItem(atPath: link)
            do {
                try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tool)
                alert.messageText = "Installed the strata command."
                alert.informativeText = "Try `strata .` in a terminal."
            } catch {
                alert.messageText = "Couldn’t install the strata command."
                alert.informativeText = error.localizedDescription
            }
        } else {
            alert.messageText = "Install the strata command"
            alert.informativeText = "/usr/local/bin isn’t writable without an administrator password. Run this in a terminal:\n\nsudo ln -sf '\(tool)' \(link)"
            alert.addButton(withTitle: "Copy Command")
            alert.addButton(withTitle: "Close")
            if alert.runModal() == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("sudo ln -sf '\(tool)' \(link)", forType: .string)
            }
            return
        }
        alert.runModal()
    }
}
