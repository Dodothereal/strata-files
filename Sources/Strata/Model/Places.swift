import AppKit

struct Place {
    let title: String
    let url: URL
    let symbol: String
}

enum Places {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

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
            return Place(title: v.volumeLocalizedName ?? url.lastPathComponent, url: url, symbol: symbol)
        }
    }
}
