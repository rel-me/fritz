import XCTest
import FritzState

@MainActor final class StateDatabaseTests: XCTestCase {
    private let initial = "CREATE TABLE records (id INTEGER PRIMARY KEY, value TEXT NOT NULL);"
    private let schema = ["records": ["id", "value"]]
    private func file() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("state.sqlite")
    }

    func testUpgradeAndReopenPreserveBoundValues() throws {
        let url = try file()
        let first = try StateDatabase(url: url, migrations: [initial], schema: schema)
        let value = "Quotes ' and Unicode 🦊\0tail"
        try first.execute("INSERT INTO records VALUES (?, ?)", [.integer(1), .text(value)])
        let upgrades = [initial, "ALTER TABLE records ADD COLUMN extra TEXT;"]
        let second = try StateDatabase(url: url, migrations: upgrades, schema: ["records": ["id", "value", "extra"]])
        XCTAssertEqual(try second.query("SELECT value FROM records").first?["value"], .text(value))
        XCTAssertEqual(try second.query("PRAGMA user_version").first?["user_version"], .integer(2))
        XCTAssertThrowsError(try StateDatabase(url: url, migrations: [initial], schema: schema))
        XCTAssertEqual(try second.query("SELECT value FROM records").count, 1)
    }

    func testFailedMigrationRollsBackDDLAndVersion() throws {
        let url = try file()
        let original = try StateDatabase(url: url, migrations: [initial], schema: schema)
        XCTAssertThrowsError(try StateDatabase(url: url, migrations: [initial, "ALTER TABLE records ADD COLUMN extra TEXT; INSERT INTO missing VALUES (1);"], schema: schema))
        XCTAssertEqual(try original.query("PRAGMA user_version").first?["user_version"], .integer(1))
        XCTAssertEqual(try original.query("SELECT name FROM pragma_table_info('records')").count, 2)
        _ = try StateDatabase(url: url, migrations: [initial], schema: schema)
    }

    func testTransactionRollbackAndForeignKeys() throws {
        let url = try file()
        let db = try StateDatabase(url: url, migrations: [initial, "CREATE TABLE children (id INTEGER PRIMARY KEY, parent INTEGER REFERENCES records(id) ON DELETE CASCADE);"], schema: ["records": ["id", "value"], "children": ["id", "parent"]])
        XCTAssertThrowsError(try db.transaction {
            try db.execute("INSERT INTO records VALUES (1, 'test')")
            try db.execute("INSERT INTO children VALUES (1, 99)")
        })
        XCTAssertTrue(try db.query("SELECT * FROM records").isEmpty)
        try db.execute("INSERT INTO records VALUES (1, 'test')")
        try db.execute("INSERT INTO children VALUES (1, 1)")
        try db.execute("DELETE FROM records")
        XCTAssertTrue(try db.query("SELECT * FROM children").isEmpty)
    }

    func testConcurrentFirstOpenAndUpdates() throws {
        let url = try file()
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            do {
                let db = try StateDatabase(url: url, migrations: ["CREATE TABLE counters (id INTEGER PRIMARY KEY, value INTEGER NOT NULL); INSERT INTO counters VALUES (1, 0);"], schema: ["counters": ["id", "value"]])
                try db.transaction { try db.execute("UPDATE counters SET value = value + 1 WHERE id = 1") }
            } catch { XCTFail("Concurrent open \(index) failed: \(error)") }
        }
        let db = try StateDatabase(url: url, migrations: ["CREATE TABLE counters (id INTEGER PRIMARY KEY, value INTEGER NOT NULL); INSERT INTO counters VALUES (1, 0);"], schema: ["counters": ["id", "value"]])
        XCTAssertEqual(try db.query("SELECT value FROM counters").first?["value"], .integer(8))
    }

    func testSchemaValidationAndCorruptionAreNotReset() throws {
        let url = try file()
        let db = try StateDatabase(url: url, migrations: [initial], schema: schema)
        try db.execute("DROP TABLE records")
        XCTAssertThrowsError(try StateDatabase(url: url, migrations: [initial], schema: schema))
        let corrupt = try file()
        try Data("invalid database".utf8).write(to: corrupt)
        XCTAssertThrowsError(try StateDatabase(url: corrupt, migrations: [initial], schema: schema))
        XCTAssertEqual(try String(contentsOf: corrupt, encoding: .utf8), "invalid database")
    }
}
