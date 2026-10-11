import Foundation
import UniformTypeIdentifiers

/// A snapshot of one directory entry, read off the main thread.
nonisolated struct FileEntry: Sendable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let isSymlink: Bool
    let isVolume: Bool
    let size: Int64?
    let modified: Date?
    let created: Date?
    let added: Date?
    let kind: String
    let contentType: UTType?

    /// A folder you navigate into (packages such as apps open instead).
    var isFolder: Bool { isDirectory && !isPackage }

    /// macOS calls `.ts` an MPEG-2 stream and has no names for many source files; developers expect these.
    static let developerKinds: [String: String] = [
        "ts": "TypeScript source", "tsx": "TypeScript JSX source", "jsx": "JavaScript JSX source", "mts": "TypeScript source",
        "rs": "Rust source", "go": "Go source", "kt": "Kotlin source", "kts": "Kotlin script", "gd": "GDScript source",
        "dart": "Dart source", "vue": "Vue component", "svelte": "Svelte component", "toml": "TOML document",
        "lock": "Lockfile", "tf": "Terraform configuration", "proto": "Protocol Buffers definition",
    ]

    /// The Kind shown everywhere (list, inspector, conflict sheet, AI plans): the system's description, except for
    /// source files macOS names wrong or not at all. `.ts` is ambiguous: small ones are TypeScript, large ones are
    /// almost always MPEG transport-stream video.
    static func kind(extension ext: String, isDirectory: Bool, isPackage: Bool, size: Int64?, system: String?) -> String {
        let ext = ext.lowercased()
        if !isDirectory, let developer = developerKinds[ext], !(ext == "ts" || ext == "mts") || (size ?? 0) < 4_000_000 {
            return developer
        }
        return system ?? (isDirectory && !isPackage ? "Folder" : "Document")
    }

    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey, .addedToDirectoryDateKey, .localizedTypeDescriptionKey,
        .contentTypeKey, .isVolumeKey,
    ]

    init(url: URL, name: String, isDirectory: Bool, isPackage: Bool, isHidden: Bool, isSymlink: Bool, isVolume: Bool,
         size: Int64?, modified: Date?, created: Date?, added: Date?, kind: String, contentType: UTType?) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isHidden = isHidden
        self.isSymlink = isSymlink
        self.isVolume = isVolume
        self.size = size
        self.modified = modified
        self.created = created
        self.added = added
        self.kind = kind
        self.contentType = contentType
    }

    init(url: URL, values: URLResourceValues) {
        self.url = url
        name = values.name ?? url.lastPathComponent
        isSymlink = values.isSymbolicLink ?? false
        isVolume = values.isVolume ?? false
        var isDirectory = values.isDirectory ?? false
        var isPackage = values.isPackage ?? false
        if isSymlink, let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) {
            isDirectory = target.isDirectory ?? false
            isPackage = target.isPackage ?? false
        }
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        isHidden = values.isHidden ?? name.hasPrefix(".")
        size = isDirectory ? nil : values.fileSize.map(Int64.init)
        modified = values.contentModificationDate
        created = values.creationDate
        added = values.addedToDirectoryDate
        kind = Self.kind(extension: url.pathExtension, isDirectory: isDirectory, isPackage: isPackage,
                         size: values.fileSize.map(Int64.init), system: values.localizedTypeDescription)
        contentType = values.contentType
    }

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys)) else { return nil }
        self.init(url: url, values: values)
    }
}

nonisolated enum DirectoryLoader {
    @concurrent
    static func load(_ directory: URL, showHidden: Bool) async throws -> [FileEntry] {
        let keys = FileEntry.resourceKeys
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: showHidden ? [] : [.skipsHiddenFiles])
        let keySet = Set(keys)
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keySet) else { return nil }
            return FileEntry(url: url, values: values)
        }
    }
}
