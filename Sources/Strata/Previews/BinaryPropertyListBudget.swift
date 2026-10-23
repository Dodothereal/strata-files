import Foundation

/// Bounds a binary plist's expanded tree before Foundation allocates it or serializes shared references to XML.
/// Repeated references count each time, and a cycle or excessive nesting is refused.
nonisolated enum BinaryPropertyListBudget {
    static func permits(_ data: Data, limit: Int = TextFile.limit) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 40, bytes.starts(with: Array("bplist00".utf8)) else { return false }
        let trailer = bytes.count - 32
        func integer(_ offset: Int, _ width: Int) -> Int? {
            guard (1...8).contains(width), offset >= 0, offset <= bytes.count - width else { return nil }
            var value: UInt64 = 0
            for byte in bytes[offset..<(offset + width)] { value = value << 8 | UInt64(byte) }
            return Int(exactly: value)
        }
        let offsetWidth = Int(bytes[trailer + 6]), referenceWidth = Int(bytes[trailer + 7])
        guard let count = integer(trailer + 8, 8), count > 0,
              let top = integer(trailer + 16, 8), top < count,
              let table = integer(trailer + 24, 8), table >= 8, table <= trailer,
              (1...8).contains(offsetWidth), (1...8).contains(referenceWidth),
              count <= (trailer - table) / offsetWidth else { return false }
        var remaining = limit - 256
        var visiting = Set<Int>()
        func visit(_ id: Int, depth: Int) -> Bool {
            guard depth < 64, id >= 0, id < count, remaining >= 64, visiting.insert(id).inserted,
                  let offset = integer(table + id * offsetWidth, offsetWidth), offset >= 8, offset < table else { return false }
            defer { visiting.remove(id) }
            remaining -= 64
            let marker = bytes[offset], kind = marker >> 4
            var length = Int(marker & 15), start = offset + 1
            if [4, 5, 6, 10, 12, 13].contains(kind), length == 15 {
                guard start < table, bytes[start] >> 4 == 1, bytes[start] & 15 <= 3 else { return false }
                let width = 1 << Int(bytes[start] & 15)
                guard start + 1 <= table - width, let value = integer(start + 1, width) else { return false }
                length = value
                start += 1 + width
            }
            switch kind {
            case 0, 1, 2, 3, 8:
                return true
            case 4, 5, 6:
                let width = kind == 6 ? 2 : 1
                guard length <= (table - start) / width, length <= remaining / (width * 6) else { return false }
                remaining -= length * width * 6
                return true
            case 10, 12, 13:
                let width = referenceWidth * (kind == 13 ? 2 : 1)
                guard length <= (table - start) / width, length <= remaining / 64 else { return false }
                for index in 0..<(length * (kind == 13 ? 2 : 1)) {
                    guard let reference = integer(start + index * referenceWidth, referenceWidth), visit(reference, depth: depth + 1) else { return false }
                }
                return true
            default:
                return false
            }
        }
        return visit(top, depth: 0)
    }
}
