import AppKit
import SwiftUI

final class ViewOptionsWindowController: NSWindowController {
    static let shared = ViewOptionsWindowController()

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 410, height: 650),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = String(localized: "View Options", comment: "Title of the window opened with Command-J")
        panel.contentViewController = NSHostingController(rootView: ViewOptionsView())
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        ThemeStyle.bind(panel)
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() { showWindow(nil) }
}

struct ViewOptionsView: View {
    @State private var options = Prefs.shared.iconViewOptions
    @State private var iconSize = Prefs.shared.gridIconSize
    @State private var previews = Prefs.shared.showIconPreviews
    @State private var hiddenColumns = Prefs.shared.hiddenListColumns

    var body: some View {
        Form {
            Section("Icons") {
                Slider(value: Binding(get: { iconSize }, set: { iconSize = $0; Prefs.shared.gridIconSize = $0 }), in: 32...256) {
                    Text("Icon size")
                }
                Toggle("Show item info", isOn: $options.showsInfo)
                Picker("Folder info", selection: $options.folderInfo) {
                    Text("Item count").tag(FolderIconInfo.itemCount)
                    Text("Total size").tag(FolderIconInfo.size)
                }
                .disabled(!options.showsInfo)
                Text("Pictures and movies show their dimensions. Other files show their size.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show icon previews", isOn: Binding(get: { previews }, set: { previews = $0; Prefs.shared.showIconPreviews = $0 }))
            }
            Section("List columns") {
                ForEach(ListColumn.allCases, id: \.self) { column in
                    Toggle(column.title, isOn: Binding(get: { !hiddenColumns.contains(column.rawValue) }, set: { shown in
                        if shown { hiddenColumns.remove(column.rawValue) } else { hiddenColumns.insert(column.rawValue) }
                        Prefs.shared.hiddenListColumns = hiddenColumns
                    }))
                }
            }
            Text("Applies to all windows.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .modifier(ThemedFormBackground())
        .onChange(of: options) { _, value in
            if value != Prefs.shared.iconViewOptions { Prefs.shared.iconViewOptions = value }
        }
        .onReceive(NotificationCenter.default.publisher(for: .viewOptionsChanged)) { _ in
            options = Prefs.shared.iconViewOptions
            iconSize = Prefs.shared.gridIconSize
        }
        .onReceive(NotificationCenter.default.publisher(for: .appearanceChanged)) { _ in previews = Prefs.shared.showIconPreviews }
        .onReceive(NotificationCenter.default.publisher(for: .listColumnsChanged)) { _ in hiddenColumns = Prefs.shared.hiddenListColumns }
    }
}
