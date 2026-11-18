import Foundation
import FritzState
import FritzUI

/// The app owns this schema. FritzState owns SQLite connections and migrations.
@MainActor final class AppDatabase: ModelsPreferences {
    private let storage: Result<StateDatabase, Error>

    init(directory: URL) {
        storage = Result {
            // The previous workspace also used version 1 for its settings table.
            // Read only that table and leave any old projects and transcripts in place.
            try StateDatabase(url: directory.appendingPathComponent("workspace.sqlite"), migrations: ["""
                CREATE TABLE settings (key TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL CHECK(json_valid(payload)));
                """], schema: ["settings": ["key", "payload"]],
                checkDataOnOpen: false, allowAdditionalTables: true)
        }
    }

    func setting<T: Decodable>(_ key: String, as: T.Type = T.self) throws -> T? {
        try storage.get().query("SELECT payload FROM settings WHERE key = ?", [.text(key)]).first.map { try decode($0) }
    }

    func set<T: Encodable>(_ value: T, for key: String) throws {
        try storage.get().execute("INSERT INTO settings VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET payload = excluded.payload", [.text(key), try encode(value)])
    }

    private func encode<T: Encodable>(_ value: T) throws -> SQLValue { .text(String(decoding: try JSONEncoder().encode(value), as: UTF8.self)) }
    private func decode<T: Decodable>(_ row: [String: SQLValue]) throws -> T {
        guard let payload = row["payload"]?.string else { throw StateDatabaseError("Missing state record.") }
        return try JSONDecoder().decode(T.self, from: Data(payload.utf8))
    }
}
