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

    @Test(arguments: [8_388_607, 8_388_608, 8_388_609])
    func valueLimitAcceptsItsBoundaryAndRefusesLargerValues(_ bytes: Int) throws {
        let tree = try TestTree()
        let url = tree.url("test.db")
        try database(url, sql: "CREATE VIEW bounded AS SELECT zeroblob(\(bytes)) AS payload")
        let before = try Data(contentsOf: url)
        let result = try SQLiteReader.rows(url, table: "bounded")
        if bytes <= 8 * 1024 * 1024 {
            #expect(result.error == nil)
            let row = try #require(result.data.rows.first)
            guard case .blob(let count) = try #require(row.first) else {
                Issue.record("Expected a BLOB size, not allocated preview text")
                return
            }
            #expect(count == bytes)
        } else {
            #expect(result.error != nil)
            #expect(result.data.rows.isEmpty)
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(tree.snapshot() == ["test.db"])
    }

    @Test func anOversizedStoredValueKeepsEarlierRowsAndReportsTheFailure() throws {
        let tree = try TestTree()
        let url = tree.url("test.db")
        try database(url, sql: """
            CREATE TABLE example (id INTEGER PRIMARY KEY, first BLOB, second BLOB);
            INSERT INTO example VALUES (1, zeroblob(16), zeroblob(32));
            INSERT INTO example VALUES (2, zeroblob(16777216), zeroblob(32));
            INSERT INTO example VALUES (3, zeroblob(16), zeroblob(32));
            """)
        let before = try Data(contentsOf: url)
        let result = try SQLiteReader.rows(url, table: "example")
        #expect(result.error != nil)
        #expect(result.data.columns.map(\.title) == ["id", "first", "second"])
        #expect(result.data.rows.count == 1)
        if let row = result.data.rows.first {
            #expect(row.map { GridView.display($0) } == ["1", GridView.display(.blob(bytes: 16)),
                                                        GridView.display(.blob(bytes: 32))])
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(tree.snapshot() == ["test.db"])
    }


    @Test func aStoredRowCanStillReadSeparateValuesThatEachFitTheLimit() throws {
        let tree = try TestTree()
        let url = tree.url("test.db")
        try database(url, sql: """
            CREATE TABLE example (first BLOB, second BLOB);
            INSERT INTO example VALUES (zeroblob(4194304), zeroblob(4194304));
            """)
        let before = try Data(contentsOf: url)
        let result = try SQLiteReader.rows(url, table: "example")
        #expect(result.error == nil)
        #expect(result.data.rows.count == 1)
        let row = try #require(result.data.rows.first)
        #expect(row.count == 2)
        for cell in row {
            if case .blob(let count) = cell { #expect(count == 4_194_304) }
            else { Issue.record("Expected the stored BLOB size") }
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(tree.snapshot() == ["test.db"])
    }
}
