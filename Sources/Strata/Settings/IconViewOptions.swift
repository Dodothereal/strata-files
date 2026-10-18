import Foundation

enum FolderIconInfo: String, CaseIterable {
    case itemCount, size
}

/// Shared by icon views in every window. Read and write through a supplied store so tests use their own preferences.
struct IconViewOptions: Equatable {
    var showsInfo = true
    var folderInfo: FolderIconInfo = .itemCount

    static func read(from defaults: UserDefaults) -> Self {
        Self(showsInfo: defaults.object(forKey: "iconShowsItemInfo") as? Bool ?? true,
             folderInfo: defaults.string(forKey: "iconFolderInfo").flatMap(FolderIconInfo.init(rawValue:)) ?? .itemCount)
    }

    func save(in defaults: UserDefaults) {
        defaults.set(showsInfo, forKey: "iconShowsItemInfo")
        defaults.set(folderInfo.rawValue, forKey: "iconFolderInfo")
    }
}
