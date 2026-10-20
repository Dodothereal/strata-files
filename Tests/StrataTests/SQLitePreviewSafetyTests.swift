import Foundation
import SQLite3
import Testing
@testable import Strata

struct SQLitePreviewSafetyTests {
    private func database(_ url: URL, sql: String) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func aViewCannotAllocateAnArbitrarilyLargeValueForAPreview() throws {
        let tree = try TestTree()
        let url = tree.url("test.db")
        // Exercise the same allocation path with 16 MiB rather than risking the system's 1 GiB default.
        try database(url, sql: "CREATE VIEW oversized AS SELECT randomblob(16777216) AS payload")
        let before = try Data(contentsOf: url)
        let rows = try SQLiteReader.rows(url, table: "oversized")
        #expect(rows.error != nil)
        #expect(rows.data.rows.isEmpty)
        #expect(try Data(contentsOf: url) == before)
        #expect(tree.snapshot() == ["test.db"])
    }

    @Test func ordinaryTablesAndViewsRemainReadOnlyAndReadable() throws {
        let tree = try TestTree()
        let url = tree.url("test.db")
        try database(url, sql: """
            CREATE TABLE example (name TEXT, amount INTEGER, payload BLOB);
            INSERT INTO example VALUES ('café 😀', 42, zeroblob(1024));
            CREATE VIEW example_view AS SELECT * FROM example;
            """)
        let before = try Data(contentsOf: url)
        #expect(try SQLiteReader.tables(url).map(\.name) == ["example", "example_view"])
        for name in ["example", "example_view"] {
            let rows = try SQLiteReader.rows(url, table: name)
            #expect(rows.error == nil)
            #expect(rows.data.columns.count == 3 && rows.data.rows.count == 1)
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(tree.snapshot() == ["test.db"])
    }
}
