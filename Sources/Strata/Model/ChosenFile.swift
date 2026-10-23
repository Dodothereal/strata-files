import Foundation

/// A chosen name and its parent held open across a confirmation or metadata change. Opening each component
/// without following links prevents a replaced ancestor from redirecting the operation.
nonisolated package final class ChosenFile: Sendable {
    package let url: URL
    package let identity: FileIdentity
    private let parentPath: String
    private let parentIdentity: FileIdentity
    private let parent: Int32

    package init(_ url: URL, resolveParent: Bool = true) throws {
        self.url = url
        guard !url.lastPathComponent.isEmpty, ![".", "..", "/"].contains(url.lastPathComponent) else { throw POSIXError(.EINVAL) }
        let path = url.deletingLastPathComponent().path
        parentPath = resolveParent ? try Self.resolvedDirectory(path) : Self.systemSpelling(path)
        parent = try Self.openDirectory(parentPath)
        var info = stat()
        guard fstat(parent, &info) == 0 else { close(parent); throw POSIXError(.ESTALE) }
        parentIdentity = .from(info)
        guard fstatat(parent, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            close(parent)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        identity = .from(info)
    }

    deinit { close(parent) }

    package static func systemSpelling(_ path: String) -> String {
        // Foundation shortens /private/var back to /var. These root-owned aliases are fixed by macOS;
        // user-controlled directory components below them are still opened with O_NOFOLLOW.
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }

    private static func resolvedDirectory(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    package static func openDirectory(_ path: String) throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        for component in systemSpelling(path).split(separator: "/") {
            guard component != ".", component != ".." else { close(fd); throw POSIXError(.EINVAL) }
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(fd)
            guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            fd = next
        }
        return fd
    }

    private func verifyParent() throws {
        guard (try? Self.resolvedDirectory(url.deletingLastPathComponent().path)) == parentPath,
              let current = try? Self.openDirectory(parentPath) else { throw POSIXError(.ESTALE) }
        defer { close(current) }
        var info = stat()
        guard fstat(current, &info) == 0, FileIdentity.from(info) == parentIdentity else { throw POSIXError(.ESTALE) }
    }

    /// The descriptor identifies the chosen item even if its name is replaced after opening it.
    package func withDescriptor<T>(_ body: (Int32, stat) throws -> T) throws -> T {
        try verifyParent()
        let fd = openat(parent, url.lastPathComponent, O_EVTONLY | O_NONBLOCK | O_SYMLINK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, FileIdentity.from(info) == identity else { throw POSIXError(.ESTALE) }
        return try body(fd, info)
    }

    /// A permissions editor must also restore access to a mode-000 item, which macOS will not open even with
    /// O_EVTONLY. Its fallback uses this checked parent and AT_SYMLINK_NOFOLLOW, never a following path call.
    package func withParent<T>(_ body: (Int32, String, stat) throws -> T) throws -> T {
        try verifyParent()
        var info = stat()
        let name = url.lastPathComponent
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, FileIdentity.from(info) == identity else {
            throw POSIXError(.ESTALE)
        }
        return try body(parent, name, info)
    }

    package func remove() throws {
        try verifyParent()
        try Self.remove(in: parent, name: url.lastPathComponent, identity: identity, depth: 0)
    }

    private static func remove(in parent: Int32, name: String, identity: FileIdentity, depth: Int) throws {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, FileIdentity.from(info) == identity else {
            throw POSIXError(.ESTALE)
        }
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        if isDirectory {
            guard depth < 512 else { throw POSIXError(.ELOOP) }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            guard fstat(fd, &info) == 0, FileIdentity.from(info) == identity else { throw POSIXError(.ESTALE) }
            let copy = dup(fd)
            guard copy >= 0, let entries = fdopendir(copy) else {
                if copy >= 0 { close(copy) }
                throw POSIXError(.EIO)
            }
            defer { closedir(entries) }
            while let entry = readdir(entries) {
                // Refuse names that cannot be represented exactly; lossy conversion could choose another item.
                try withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    let bytes = raw.prefix { $0 != 0 }
                    guard !bytes.elementsEqual([46]), !bytes.elementsEqual([46, 46]) else { return }
                    guard let child = String(bytes: bytes, encoding: .utf8) else { throw POSIXError(.EILSEQ) }
                    guard fstatat(fd, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw POSIXError(.ESTALE) }
                    try remove(in: fd, name: child, identity: .from(info), depth: depth + 1)
                }
            }
        }
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, FileIdentity.from(info) == identity else {
            throw POSIXError(.ESTALE)
        }
        guard unlinkat(parent, name, isDirectory ? AT_REMOVEDIR : 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
