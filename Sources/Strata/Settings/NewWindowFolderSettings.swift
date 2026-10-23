import AppKit
import SwiftUI

struct NewWindowFolderSettings: View {
    let preferences: Prefs
    @State private var choice: NewWindowLocation
    @State private var folder: URL?

    init(preferences: Prefs) {
        self.preferences = preferences
        _choice = State(initialValue: preferences.newWindowLocation)
        _folder = State(initialValue: preferences.customWindowFolder)
    }

    var body: some View {
        Picker("New windows open", selection: Binding(get: { choice }, set: {
            choice = $0
            preferences.newWindowLocation = $0
        })) {
            Text("Where you left off").tag(NewWindowLocation.lastVisited)
            Text("Your home folder").tag(NewWindowLocation.home)
            Text("Custom folder").tag(NewWindowLocation.custom)
        }
        if choice == .custom {
            LabeledContent("Folder") {
                HStack {
                    if let folder {
                        Text(folder.path).lineLimit(1).truncationMode(.middle).help(folder.path)
                    }
                    Button("Choose Folder…", action: chooseFolder)
                }
            }
            Text("If the folder is unavailable, Strata opens your home folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = folder
        panel.begin { response in
            guard response == .OK, let selected = panel.url else { return }
            folder = selected
            preferences.customWindowFolder = selected
        }
    }
}
