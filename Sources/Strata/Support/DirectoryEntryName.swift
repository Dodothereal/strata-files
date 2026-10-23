import Foundation

/// libc packs dirents to d_reclen bytes. Copying the imported fixed-size d_name tuple can read past that record
/// and the end of its buffer; inspect the header and copy only the actual name instead.
nonisolated package enum DirectoryEntryName {
    private static let nameOffset = MemoryLayout<dirent>.offset(of: \.d_name)!
    private static let nameCapacity = MemoryLayout.size(ofValue: dirent().d_name)

    package static func read(_ entry: UnsafePointer<dirent>) -> String? {
        let length = Int(entry.pointee.d_namlen), recordLength = Int(entry.pointee.d_reclen)
        guard length > 0, length < nameCapacity, recordLength > nameOffset,
              length < recordLength - nameOffset else { return nil }
        let start = UnsafeRawPointer(entry).advanced(by: nameOffset)
        guard start.load(fromByteOffset: length, as: UInt8.self) == 0 else { return nil }
        let bytes = UnsafeRawBufferPointer(start: start, count: length)
        guard !bytes.contains(0), !bytes.contains(47) else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }
}
