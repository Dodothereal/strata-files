import Foundation
import SQLite3

nonisolated struct SQLiteTable: Sendable {
    let name: String
    let isView: Bool
    /// nil when counting took too long (or for views, which aren't counted).
    let rowCount: Int?
}

nonisolated struct SQLiteRows: Sendable {
    let data: GridData
    /// Why the rows couldn't be read (a virtual table from a missing module, say); the grid stays empty.
    let error: String?
}

/// Read-only access to SQLite files. Every call opens its own immutable, read-only connection, so nothing is
/// shared between threads and the file (or its -wal/-shm siblings) is never written or locked.
nonisolated enum SQLiteReader {
    static let rowLimit = 200

    static func isSQLite(_ url: URL) throws -> Bool {
        let (head, _) = try TextFile.readPrefix(url, limit: 16)
        return head == Data("SQLite format 3\0".utf8)
    }

    /// Tables and views, with row counts that each get a small time budget.
    static func tables(_ url: URL) throws -> [SQLiteTable] {
        let db = try open(url)
        defer { sqlite3_close_v2(db) }
        let sql = "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY type, name COLLATE NOCASE"
        var entries: [(String, Bool)] = []
        try withBudget(db, 2) {
            try query(db, sql) { statement in
                entries.append((text(statement, 0) ?? "", text(statement, 1) == "view"))
            }
        }
        let started = Date()
        return try entries.map { name, isView in
            try Task.checkCancellation()
            guard !isView, Date().timeIntervalSince(started) < 1.5 else { return SQLiteTable(name: name, isView: isView, rowCount: nil) }
            return SQLiteTable(name: name, isView: isView, rowCount: count(db, table: name, budget: 0.3))
        }
    }

    /// The first `rowLimit` rows of `table`. A view is the file's own SQL, so reading gets a time budget.
    static func rows(_ url: URL, table: String) throws -> SQLiteRows {
        let db = try open(url)
        defer { sqlite3_close_v2(db) }
        return withBudget(db, 3) { readRows(db, table: table) }
    }

    private static func readRows(_ db: OpaquePointer?, table: String) -> SQLiteRows {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM \(quoted(table)) LIMIT \(rowLimit)", -1, &statement, nil) == SQLITE_OK else {
            return SQLiteRows(data: GridData(columns: [], rows: []), error: message(db))
        }
        defer { sqlite3_finalize(statement) }
        let columnCount = Int(sqlite3_column_count(statement))
        var columns = (0..<columnCount).map { GridColumn(title: sqlite3_column_name(statement, Int32($0)).map { String(cString: $0) } ?? "") }
        var numeric = Array(repeating: true, count: columnCount)
        var rows: [[GridValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                let error = step == SQLITE_INTERRUPT ? "Reading this took too long; showing what was read in time." : message(db)
                return SQLiteRows(data: GridData(columns: columns, rows: rows), error: error)
            }
            var row: [GridValue] = []
            row.reserveCapacity(columnCount)
            for index in 0..<columnCount {
                let column = Int32(index)
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER:
                    row.append(.text(String(sqlite3_column_int64(statement, column))))
                case SQLITE_FLOAT:
                    row.append(.text(String(sqlite3_column_double(statement, column))))
                case SQLITE_NULL:
                    row.append(.null)
                case SQLITE_BLOB:
                    row.append(.blob(bytes: Int(sqlite3_column_bytes(statement, column))))
                    numeric[index] = false
                default:
                    let value = text(statement, column) ?? ""
                    row.append(.text(value.count > 300 ? String(value.prefix(300)) + "…" : value))
                    numeric[index] = false
                }
            }
            rows.append(row)
        }
        for index in columns.indices { columns[index].isNumeric = numeric[index] && !rows.isEmpty }
        var data = GridData(columns: columns, rows: rows)
        data.measureColumns()
        return SQLiteRows(data: data, error: nil)
    }

    // MARK: - Helpers

    private static func open(_ url: URL) throws -> OpaquePointer? {
        var components = URLComponents()
        components.scheme = "file"
        components.path = url.path
        components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        var db: OpaquePointer?
        let status = sqlite3_open_v2(components.string ?? url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard status == SQLITE_OK else {
            sqlite3_close_v2(db)
            throw PreviewError.message("This database couldn't be opened.")
        }
        // The schema is the file's: don't let its views or triggers call functions with side effects.
        sqlite3_exec(db, "PRAGMA trusted_schema = OFF", nil, nil, nil)
        // A corrupt or encrypted file opens fine and fails on the first read.
        guard withBudget(db, 2, { sqlite3_exec(db, "SELECT count(*) FROM sqlite_master", nil, nil, nil) }) == SQLITE_OK else {
            sqlite3_close_v2(db)
            throw PreviewError.message("This database is encrypted or damaged.", symbol: "lock")
        }
        return db
    }

    private static func query(_ db: OpaquePointer?, _ sql: String, row: (OpaquePointer?) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw PreviewError.message(message(db)) }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { try row(statement) }
    }

    /// `count(*)`, interrupted after `budget` seconds so huge tables don't stall the preview.
    private static func count(_ db: OpaquePointer?, table: String, budget: TimeInterval) -> Int? {
        var result: Int?
        withBudget(db, budget) {
            try? query(db, "SELECT count(*) FROM \(quoted(table))") { statement in
                result = Int(sqlite3_column_int64(statement, 0))
            }
        }
        return result
    }

    /// Runs `body` with SQLite interrupting any statement once `budget` seconds pass or the preview is cancelled
    /// (a crafted view with a runaway recursive query would otherwise spin forever).
    private static func withBudget<T>(_ db: OpaquePointer?, _ budget: TimeInterval, _ body: () throws -> T) rethrows -> T {
        let deadline = Deadline(date: Date().addingTimeInterval(budget))
        let context = Unmanaged.passRetained(deadline)
        defer {
            sqlite3_progress_handler(db, 0, nil, nil)
            context.release()
        }
        sqlite3_progress_handler(db, 5_000, { pointer in
            guard let pointer else { return 0 }
            return Date() > Unmanaged<Deadline>.fromOpaque(pointer).takeUnretainedValue().date || Task.isCancelled ? 1 : 0
        }, context.toOpaque())
        return try body()
    }

    private final class Deadline {
        let date: Date
        init(date: Date) { self.date = date }
    }

    private static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private static func message(_ db: OpaquePointer?) -> String {
        sqlite3_errmsg(db).map { String(cString: $0) } ?? "Unknown error"
    }
}
