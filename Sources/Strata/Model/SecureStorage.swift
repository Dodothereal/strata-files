import CryptoKit
import Foundation
import Security
import os

/// Strata's saved state (the file index, the content index, the operation history) reveals what is inside folders that
/// macOS guards with privacy prompts, like Documents, Desktop and Downloads. A plain copy would let anything running as
/// you read it without ever asking. So every store is encrypted (AES-GCM) with a key kept in your login keychain, which
/// only Strata can read without asking you, in a folder private to your account. Files are written to a fresh
/// temporary name (never following a planted symlink) and swapped in atomically.
nonisolated enum SecureStorage {
    private static let log = Logger(subsystem: "dev.strata.app", category: "storage")

    /// `~/Library/Application Support/Strata`, owner-only.
    static let directory: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "Strata", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        chmod(url.path, 0o700)
        return url
    }()

    /// A file or folder inside `directory`. Subfolders are created owner-only.
    static func url(_ relative: String, isDirectory: Bool = false) -> URL {
        let url = directory.appending(path: relative, directoryHint: isDirectory ? .isDirectory : .notDirectory)
        let folder = isDirectory ? url : url.deletingLastPathComponent()
        if folder.standardizedFileURL != directory.standardizedFileURL {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            chmod(folder.path, 0o700)
        }
        return url
    }

    /// Deletes a store left over from before encryption (and its stray temporary file).
    static func removeLegacy(_ url: URL) {
        for path in [url.path, url.path + ".tmp"] where FileManager.default.fileExists(atPath: path) {
            unlink(path)
        }
    }

    // MARK: Key

    /// The key, created on first use. Nil if the keychain can't provide one; stores then aren't saved at all.
    static let key: SymmetricKey? = loadOrCreateKey()

    private static let service = "Strata Safe Storage"
    private static let account = "dev.strata.app"

    private static func loadOrCreateKey() -> SymmetricKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else {
            log.error("Keychain key unavailable (\(status)); saved state disabled")
            return nil
        }
        let key = SymmetricKey(size: .bits256)
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecAttrLabel: service, kSecAttrDescription: "Encrypts Strata's search index and history",
            kSecValueData: key.withUnsafeBytes { Data($0) },
        ]
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else {
            log.error("Couldn't store keychain key (\(added)); saved state disabled")
            return nil
        }
        return key
    }

    // MARK: Whole files

    static func write(_ data: Data, to url: URL) throws {
        let writer = try Writer(url: url)
        data.withUnsafeBytes { writer.write($0) }
        try writer.commit()
    }

    static func read(_ url: URL) -> Data? {
        guard let reader = try? Reader(url: url) else { return nil }
        return try? reader.readToEnd()
    }

    // MARK: Streams

    /// Format: magic, version, then chunks of up to 1 MiB plaintext, each a length-prefixed AES-GCM box whose
    /// associated data is its index and whether it's the last one (so chunks can't be reordered or cut off).
    private static let magic: UInt32 = 0x5354_5253 // "STRS"
    private static let formatVersion: UInt32 = 1
    private static let chunkSize = 1 << 20
    private static let boxOverhead = 12 + 16

    struct Failure: Error {}

    private static func associatedData(_ index: UInt64, final: Bool) -> Data {
        var data = withUnsafeBytes(of: index.littleEndian) { Data($0) }
        data.append(final ? 1 : 0)
        return data
    }

    /// Streams sealed chunks to a fresh temporary file; `commit()` swaps it into place.
    final class Writer {
        private let url: URL
        private let temporary: String
        private let key: SymmetricKey
        private var fd: Int32
        private var buffer = Data()
        private var chunkIndex: UInt64 = 0
        private var failed = false

        init(url: URL) throws {
            guard let key = SecureStorage.key else { throw Failure() }
            self.url = url
            self.key = key
            temporary = url.path + "." + UUID().uuidString + ".tmp"
            fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            buffer.reserveCapacity(chunkSize)
            var header = Data()
            withUnsafeBytes(of: magic.littleEndian) { header.append(contentsOf: $0) }
            withUnsafeBytes(of: formatVersion.littleEndian) { header.append(contentsOf: $0) }
            header.withUnsafeBytes { put($0) }
        }

        deinit {
            if fd >= 0 {
                close(fd)
                unlink(temporary)
            }
        }

        func write(_ bytes: UnsafeRawBufferPointer) {
            var offset = 0
            while offset < bytes.count && !failed {
                let take = min(chunkSize - buffer.count, bytes.count - offset)
                buffer.append(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self) + offset, count: take)
                offset += take
                if buffer.count == chunkSize { flush(final: false) }
            }
        }

        func commit() throws {
            flush(final: true)
            let closed = close(fd)
            fd = -1
            guard !failed, closed == 0 else {
                unlink(temporary)
                throw Failure()
            }
            // rename() replaces whatever sits at `url`, a symlink included, without following it.
            guard rename(temporary, url.path) == 0 else {
                unlink(temporary)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        private func flush(final: Bool) {
            guard !failed else { return }
            guard let box = try? AES.GCM.seal(buffer, using: key,
                                              authenticating: associatedData(chunkIndex, final: final)),
                  let combined = box.combined else {
                failed = true
                return
            }
            var length = UInt32(combined.count).littleEndian
            withUnsafeBytes(of: &length) { put($0) }
            combined.withUnsafeBytes { put($0) }
            chunkIndex += 1
            buffer.removeAll(keepingCapacity: true)
        }

        private func put(_ bytes: UnsafeRawBufferPointer) {
            var offset = 0
            while offset < bytes.count && !failed {
                let written = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if written <= 0 { failed = true } else { offset += written }
            }
        }
    }

    /// Reads and authenticates a sealed file one chunk at a time.
    final class Reader {
        private let handle: FileHandle
        private let key: SymmetricKey
        private var chunk = Data()
        private var position = 0
        private var chunkIndex: UInt64 = 0
        private var sawFinal = false
        /// Upper bound on the plaintext, for sanity-checking lengths before allocating.
        let maximumLength: Int

        init(url: URL) throws {
            guard let key = SecureStorage.key else { throw Failure() }
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                close(fd)
                throw Failure()
            }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            self.key = key
            maximumLength = Int(info.st_size)
            guard let header = try handle.read(upToCount: 8), header.count == 8,
                  header.withUnsafeBytes({ UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }) == magic,
                  header.withUnsafeBytes({ UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }) == formatVersion
            else { throw Failure() }
        }

        /// Fills `destination` completely, or throws.
        func read(into destination: UnsafeMutableRawBufferPointer) throws {
            var filled = 0
            while filled < destination.count {
                if position == chunk.count { try nextChunk() }
                let take = min(chunk.count - position, destination.count - filled)
                chunk.withUnsafeBytes { source in
                    _ = memcpy(destination.baseAddress! + filled, source.baseAddress! + position, take)
                }
                position += take
                filled += take
            }
        }

        func readToEnd() throws -> Data {
            var data = Data()
            while true {
                if position < chunk.count {
                    data.append(chunk[position...])
                    position = chunk.count
                }
                if sawFinal { break }
                try nextChunk()
            }
            try finish()
            return data
        }

        /// Confirms everything was consumed, through the final chunk (which is empty when the data filled the last one).
        func finish() throws {
            if position == chunk.count && !sawFinal { try nextChunk() }
            guard sawFinal, position == chunk.count, try handle.read(upToCount: 1)?.isEmpty ?? true else { throw Failure() }
        }

        private func nextChunk() throws {
            guard !sawFinal, let prefix = try handle.read(upToCount: 4), prefix.count == 4 else { throw Failure() }
            let length = Int(prefix.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
            guard length >= boxOverhead, length <= chunkSize + boxOverhead,
                  let combined = try handle.read(upToCount: length), combined.count == length else { throw Failure() }
            let box = try AES.GCM.SealedBox(combined: combined)
            // The last chunk is the only one sealed as final; try that only when a full-size chunk didn't open.
            if let plain = try? AES.GCM.open(box, using: key, authenticating: associatedData(chunkIndex, final: false)) {
                chunk = plain
            } else {
                chunk = try AES.GCM.open(box, using: key, authenticating: associatedData(chunkIndex, final: true))
                sawFinal = true
            }
            position = 0
            chunkIndex += 1
        }
    }
}
