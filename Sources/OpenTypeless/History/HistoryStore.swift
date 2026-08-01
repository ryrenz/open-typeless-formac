import Foundation
import SQLite3

final class HistoryStore {
    static let shared = HistoryStore()
    static let didChangeNotification = Notification.Name("HistoryStoreDidChange")

    private let dbURL: URL
    private let calendar: Calendar
    private let fileManager: FileManager
    private var db: OpaquePointer?

    init(
        dbURL: URL = HistoryStore.defaultDatabaseURL(),
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) {
        self.dbURL = dbURL
        self.calendar = calendar
        self.fileManager = fileManager

        do {
            try openDatabase()
            try configureDatabase()
            _ = pruneExpiredRecords()
        } catch {
            fatalError("Failed to initialize HistoryStore: \(error.localizedDescription)")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    func loadAll() -> [HistoryEntry] {
        _ = pruneExpiredRecords()

        let sql = """
        SELECT id, created_at, text
        FROM history_entries
        ORDER BY created_at DESC, rowid DESC;
        """

        do {
            let statement = try prepareStatement(sql: sql)
            defer { sqlite3_finalize(statement) }

            var entries: [HistoryEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let idCString = sqlite3_column_text(statement, 0),
                    let textCString = sqlite3_column_text(statement, 2),
                    let id = UUID(uuidString: String(cString: idCString))
                else {
                    continue
                }

                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                let text = String(cString: textCString)
                entries.append(HistoryEntry(id: id, createdAt: createdAt, text: text))
            }

            return entries
        } catch {
            assertionFailure("Failed to load history: \(error.localizedDescription)")
            return []
        }
    }

    func append(text: String, createdAt: Date = Date()) {
        let normalizedText = Self.normalizedText(from: text)
        let sql = """
        INSERT INTO history_entries (id, created_at, text)
        VALUES (?, ?, ?);
        """

        do {
            let statement = try prepareStatement(sql: sql)
            defer { sqlite3_finalize(statement) }

            let id = UUID().uuidString
            sqlite3_bind_text(statement, 1, id, -1, sqliteTransient)
            sqlite3_bind_double(statement, 2, createdAt.timeIntervalSince1970)
            sqlite3_bind_text(statement, 3, normalizedText, -1, sqliteTransient)

            try step(statement)
            _ = pruneExpiredRecords()
            postDidChangeNotification()
        } catch {
            assertionFailure("Failed to append history entry: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func delete(id: UUID) throws -> Bool {
        let sql = "DELETE FROM history_entries WHERE id = ?;"

        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, id.uuidString, -1, sqliteTransient)
        try step(statement)
        let didDelete = sqlite3_changes(db) > 0
        if didDelete {
            try secureDeletionCheckpoint()
            postDidChangeNotification()
        }
        return didDelete
    }

    @discardableResult
    func deleteAll() throws -> Int {
        try execute(sql: "DELETE FROM history_entries;")
        let deletedCount = Int(sqlite3_changes(db))
        if deletedCount > 0 {
            try secureDeletionCheckpoint()
            postDidChangeNotification()
        }
        return deletedCount
    }

    func retentionPolicy() -> HistoryRetentionPolicy {
        let sql = """
        SELECT value
        FROM history_settings
        WHERE key = ?;
        """

        do {
            let statement = try prepareStatement(sql: sql)
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, "retention_policy", -1, sqliteTransient)

            guard sqlite3_step(statement) == SQLITE_ROW,
                  let valueCString = sqlite3_column_text(statement, 0)
            else {
                return .keepForever
            }

            let value = String(cString: valueCString)
            return HistoryRetentionPolicy(rawValue: value) ?? .keepForever
        } catch {
            assertionFailure("Failed to load history retention policy: \(error.localizedDescription)")
            return .keepForever
        }
    }

    func setRetentionPolicy(_ policy: HistoryRetentionPolicy) {
        let sql = """
        INSERT INTO history_settings (key, value)
        VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """

        do {
            let statement = try prepareStatement(sql: sql)
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, "retention_policy", -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, policy.rawValue, -1, sqliteTransient)
            try step(statement)

            _ = pruneExpiredRecords()
            postDidChangeNotification()
        } catch {
            assertionFailure("Failed to save history retention policy: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func pruneExpiredRecords(referenceDate: Date = Date()) -> Int {
        guard let cutoffDate = retentionPolicy().cutoffDate(referenceDate: referenceDate, calendar: calendar) else {
            return 0
        }

        let sql = """
        DELETE FROM history_entries
        WHERE created_at < ?;
        """

        do {
            let statement = try prepareStatement(sql: sql)
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_double(statement, 1, cutoffDate.timeIntervalSince1970)
            try step(statement)
            let deletedCount = Int(sqlite3_changes(db))
            if deletedCount > 0 {
                try secureDeletionCheckpoint()
            }
            return deletedCount
        } catch {
            assertionFailure("Failed to prune history entries: \(error.localizedDescription)")
            return 0
        }
    }

    static func normalizedText(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Audio is silent" : trimmed
    }

    private func openDatabase() throws {
        let directory = dbURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw makeError(message: "Unable to open SQLite database")
        }
    }

    private func configureDatabase() throws {
        try execute(sql: "PRAGMA journal_mode = WAL;")
        try execute(sql: "PRAGMA synchronous = NORMAL;")
        try execute(sql: "PRAGMA secure_delete = ON;")
        try execute(sql: "PRAGMA foreign_keys = ON;")
        try execute(sql: """
        CREATE TABLE IF NOT EXISTS history_entries (
            id TEXT PRIMARY KEY NOT NULL,
            created_at REAL NOT NULL,
            text TEXT NOT NULL
        );
        """)
        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_history_entries_created_at
        ON history_entries(created_at DESC);
        """)
        try execute(sql: """
        CREATE TABLE IF NOT EXISTS history_settings (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """)
    }

    private func execute(sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to execute SQL")
        }
    }

    private func secureDeletionCheckpoint() throws {
        try execute(sql: "PRAGMA wal_checkpoint(TRUNCATE);")
    }

    private func prepareStatement(sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw makeError(message: "Failed to prepare SQL statement")
        }
        return statement
    }

    private func step(_ statement: OpaquePointer?) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw makeError(message: "Failed to execute SQL statement")
        }
    }

    private func makeError(message: String) -> NSError {
        let detail = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown SQLite error"
        return NSError(domain: "HistoryStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(message): \(detail)"])
    }

    private func postDidChangeNotification() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private static func defaultDatabaseURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseURL
            .appendingPathComponent("OpenTypeless", isDirectory: true)
            .appendingPathComponent("history.sqlite", isDirectory: false)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
