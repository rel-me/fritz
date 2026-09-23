import Foundation
import FritzState

/// The app owns this schema. FritzState owns SQLite connections and migrations.
@MainActor final class AppDatabase {
    private let storage: Result<StateDatabase, Error>

    init(directory: URL) {
        storage = Result {
            try StateDatabase(url: directory.appendingPathComponent("workspace.sqlite"), migrations: ["""
                CREATE TABLE projects (id TEXT PRIMARY KEY NOT NULL, position INTEGER NOT NULL, payload TEXT NOT NULL CHECK(json_valid(payload)));
                CREATE TABLE threads (id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE, position INTEGER NOT NULL, payload TEXT NOT NULL CHECK(json_valid(payload)));
                CREATE TABLE workspace (id INTEGER PRIMARY KEY CHECK(id = 1), selected_thread_id TEXT REFERENCES threads(id) ON DELETE SET NULL);
                INSERT INTO workspace VALUES (1, NULL);
                CREATE TABLE messages (thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, position INTEGER NOT NULL, payload TEXT NOT NULL CHECK(json_valid(payload)), PRIMARY KEY(thread_id, position));
                CREATE TABLE thread_preferences (thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE, payload TEXT NOT NULL CHECK(json_valid(payload)));
                CREATE TABLE settings (key TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL CHECK(json_valid(payload)));
                """], schema: [
                    "projects": ["id", "position", "payload"],
                    "threads": ["id", "project_id", "position", "payload"],
                    "workspace": ["id", "selected_thread_id"],
                    "messages": ["thread_id", "position", "payload"],
                    "thread_preferences": ["thread_id", "payload"],
                    "settings": ["key", "payload"],
                ])
        }
    }

    func loadWorkspace() throws -> WorkspaceDocument {
        let db = try storage.get()
        return try db.transaction {
            var projects: [FritzProject] = []
            for row in try db.query("SELECT id, payload FROM projects ORDER BY position") {
                var project: FritzProject = try decode(row)
                guard row["id"]?.string == project.id.uuidString else { throw StateDatabaseError("Invalid project identity.") }
                project.threads = try db.query("SELECT id, payload FROM threads WHERE project_id = ? ORDER BY position", [.text(project.id.uuidString)]).map { row in
                    let thread: ProjectThread = try decode(row)
                    guard row["id"]?.string == thread.id.uuidString else { throw StateDatabaseError("Invalid thread identity.") }
                    return thread
                }
                projects.append(project)
            }
            guard let selection = try db.query("SELECT selected_thread_id FROM workspace WHERE id = 1").first else {
                throw StateDatabaseError("Missing workspace selection record.")
            }
            let selected = selection["selected_thread_id"]?.string
            if let selected, UUID(uuidString: selected) == nil { throw StateDatabaseError("Invalid selected thread identity.") }
            let document = WorkspaceDocument(projects: projects, selectedThreadID: selected.flatMap(UUID.init(uuidString:)))
            try document.validate()
            return document
        }
    }

    func saveWorkspace(_ document: WorkspaceDocument) throws {
        try document.validate()
        let db = try storage.get()
        try db.transaction {
            for (position, project) in document.projects.enumerated() {
                var metadata = project
                metadata.threads = []
                try db.execute("INSERT INTO projects VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET position = excluded.position, payload = excluded.payload", [.text(project.id.uuidString), .integer(Int64(position)), try encode(metadata)])
                for (position, thread) in project.threads.enumerated() {
                    try db.execute("INSERT INTO threads VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET project_id = excluded.project_id, position = excluded.position, payload = excluded.payload", [.text(thread.id.uuidString), .text(project.id.uuidString), .integer(Int64(position)), try encode(thread)])
                }
            }
            let ids = Set(document.projects.flatMap(\.threads).map { $0.id.uuidString })
            for row in try db.query("SELECT id FROM threads") {
                if let id = row["id"]?.string, !ids.contains(id) { try db.execute("DELETE FROM threads WHERE id = ?", [.text(id)]) }
            }
            let projectIDs = Set(document.projects.map { $0.id.uuidString })
            for row in try db.query("SELECT id FROM projects") {
                if let id = row["id"]?.string, !projectIDs.contains(id) { try db.execute("DELETE FROM projects WHERE id = ?", [.text(id)]) }
            }
            try db.execute("UPDATE workspace SET selected_thread_id = ? WHERE id = 1", [document.selectedThreadID.map { .text($0.uuidString) } ?? .null])
        }
    }

    func messages(for id: UUID) throws -> [ChatMessage] {
        try storage.get().query("SELECT payload FROM messages WHERE thread_id = ? ORDER BY position", [.text(id.uuidString)]).map { try decode($0) }
    }

    func preferences(for id: UUID) throws -> ChatPreferences? {
        try storage.get().query("SELECT payload FROM thread_preferences WHERE thread_id = ?", [.text(id.uuidString)]).first.map { try decode($0) }
    }

    func save(messages: [ChatMessage], preferences: ChatPreferences, for id: UUID) throws {
        let db = try storage.get()
        try db.transaction {
            try db.execute("DELETE FROM messages WHERE thread_id = ?", [.text(id.uuidString)])
            for (position, message) in messages.enumerated() {
                try db.execute("INSERT INTO messages VALUES (?, ?, ?)", [.text(id.uuidString), .integer(Int64(position)), try encode(message)])
            }
            try save(preferences: preferences, for: id)
        }
    }

    func save(preferences: ChatPreferences, for id: UUID) throws {
        try storage.get().execute("INSERT INTO thread_preferences VALUES (?, ?) ON CONFLICT(thread_id) DO UPDATE SET payload = excluded.payload", [.text(id.uuidString), try encode(preferences)])
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
