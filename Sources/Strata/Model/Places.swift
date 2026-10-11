import AppKit

struct Place {
    let title: String
    let url: URL
    let symbol: String
    /// A removable, ejectable or network volume.
    var isEjectable = false
}

enum Places {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Unmounts (and for disks, ejects) the volume at `url` off the main thread; reports a failure in `window`.
    static func eject(_ url: URL, from window: NSWindow?) {
        let name = FileManager.default.displayName(atPath: url.path)
        Task.detached {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "“\(name)” couldn’t be ejected"
                    alert.informativeText = "Close any files from it that are open in other apps, then try again. (\(error.localizedDescription))"
                    if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
                }
            }
        }
    }

    /// Whether `url` is the root of a volume that can be ejected.
    static func isEjectableVolume(_ url: URL) -> Bool {
        volumes().contains { $0.isEjectable && $0.url.standardizedFileURL.path == url.standardizedFileURL.path }
    }

    static func favorites() -> [Place] {
        let fm = FileManager.default
        var places = [
            Place(title: NSUserName(), url: home, symbol: "house"),
            Place(title: "Desktop", url: home.appending(path: "Desktop"), symbol: "menubar.dock.rectangle"),
            Place(title: "Documents", url: home.appending(path: "Documents"), symbol: "doc"),
            Place(title: "Downloads", url: home.appending(path: "Downloads"), symbol: "arrow.down.circle"),
            Place(title: "Applications", url: URL(fileURLWithPath: "/Applications"), symbol: "square.grid.2x2"),
        ]
        // Common homes for source code get a spot without any setup.
        for path in ["Developer", "Projects", "Code", "code", "src", "repos", "Documents/GitHub", "GitHub"] {
            let url = home.appending(path: path)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
               !places.contains(where: { $0.url.path.lowercased() == url.path.lowercased() }) {
                places.append(Place(title: url.lastPathComponent, url: url, symbol: "chevron.left.forwardslash.chevron.right"))
            }
        }
        let iCloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) {
            places.append(Place(title: "iCloud Drive", url: iCloud, symbol: "icloud"))
        }
        return places
    }

    static func volumes() -> [Place] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey,
            .volumeIsBrowsableKey, .volumeIsRootFileSystemKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable ?? true else { return nil }
            let symbol: String
            if v.volumeIsLocal == false {
                symbol = "network"
            } else if v.volumeIsRemovable == true || v.volumeIsEjectable == true {
                symbol = "externaldrive"
            } else {
                symbol = "internaldrive"
            }
            return Place(title: v.volumeLocalizedName ?? url.lastPathComponent, url: url, symbol: symbol,
                         isEjectable: v.volumeIsRootFileSystem != true
                             && (v.volumeIsLocal == false || v.volumeIsRemovable == true || v.volumeIsEjectable == true))
        }
    }
}
