import Foundation
import SQLite3

/// Versioned local store for Direction A's durable objects. Rooms and Looks
/// are first-class ordered rows; supporting native state is kept in one
/// versioned metadata payload so migrations remain atomic without flattening
/// capability-specific snapshots into lossy columns.
final class SQLiteStateDatabase {
    static let storeVersion: Int32 = 1

    enum DatabaseError: Error {
        case open(String)
        case sqlite(String)
        case missingState
        case unsupportedVersion(Int32)
        case malformedPayload
    }

    let fileURL: URL
    let backupURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        backupURL = fileURL.appendingPathExtension("backup")
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    static func isSQLiteFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 16) else { return false }
        return prefix == Data("SQLite format 3\0".utf8)
    }

    func load() throws -> PersistedApplicationState {
        try load(from: fileURL)
    }

    func loadBackup() throws -> PersistedApplicationState {
        try load(from: backupURL)
    }

    func save(_ state: PersistedApplicationState) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let database = try open(fileURL, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        var databaseIsOpen = true
        defer {
            if databaseIsOpen { sqlite3_close(database) }
        }
        try configure(database)
        try migrate(database)
        try execute("BEGIN IMMEDIATE TRANSACTION", in: database)
        do {
            try execute("DELETE FROM rooms", in: database)
            try execute("DELETE FROM looks", in: database)
            try writeRooms(state.rooms, in: database)
            try writeLooks(state.scenes, in: database)

            var support = state
            support.rooms = []
            support.scenes = []
            let payload = try encoder.encode(support)
            try writeMetadata(key: "application_state", value: payload, in: database)
            try writeMetadata(
                key: "schema_version",
                value: Data(String(state.schemaVersion).utf8),
                in: database
            )
            try execute("COMMIT TRANSACTION", in: database)
        } catch {
            try? execute("ROLLBACK TRANSACTION", in: database)
            throw error
        }
        sqlite3_close(database)
        databaseIsOpen = false
        try refreshBackup()
    }

    private func load(from url: URL) throws -> PersistedApplicationState {
        guard fileManager.fileExists(atPath: url.path), Self.isSQLiteFile(at: url) else {
            throw DatabaseError.missingState
        }
        let database = try open(url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close(database) }
        try configure(database)
        try migrate(database)
        guard let payload = try readMetadata(key: "application_state", in: database),
              var state = try? decoder.decode(PersistedApplicationState.self, from: payload) else {
            throw DatabaseError.malformedPayload
        }
        state.rooms = try readRows(
            sql: "SELECT payload FROM rooms ORDER BY position ASC",
            as: Room.self,
            in: database
        )
        state.scenes = try readRows(
            sql: "SELECT payload FROM looks ORDER BY position ASC",
            as: LightingScene.self,
            in: database
        )
        return state
    }

    private func open(_ url: URL, flags: Int32) throws -> OpaquePointer {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite could not open the database."
            if let database { sqlite3_close(database) }
            throw DatabaseError.open(message)
        }
        return database
    }

    private func configure(_ database: OpaquePointer) throws {
        try execute("PRAGMA foreign_keys = ON", in: database)
        try execute("PRAGMA journal_mode = DELETE", in: database)
        try execute("PRAGMA synchronous = FULL", in: database)
    }

    private func migrate(_ database: OpaquePointer) throws {
        let version = try integerQuery("PRAGMA user_version", in: database)
        guard version <= Self.storeVersion else {
            throw DatabaseError.unsupportedVersion(version)
        }
        if version == 0 {
            try execute(
                """
                CREATE TABLE IF NOT EXISTS metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value BLOB NOT NULL
                )
                """,
                in: database
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS rooms (
                    id TEXT PRIMARY KEY NOT NULL,
                    position INTEGER NOT NULL,
                    payload BLOB NOT NULL
                )
                """,
                in: database
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS looks (
                    id TEXT PRIMARY KEY NOT NULL,
                    position INTEGER NOT NULL,
                    payload BLOB NOT NULL
                )
                """,
                in: database
            )
            try execute("PRAGMA user_version = \(Self.storeVersion)", in: database)
        }
    }

    private func writeRooms(_ rooms: [Room], in database: OpaquePointer) throws {
        let statement = try prepare(
            "INSERT INTO rooms (id, position, payload) VALUES (?, ?, ?)",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        for (position, room) in rooms.enumerated() {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bind(room.id.uuidString.lowercased(), at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, sqlite3_int64(position))
            try bind(try encoder.encode(room), at: 3, to: statement)
            try requireDone(statement, in: database)
        }
    }

    private func writeLooks(_ looks: [LightingScene], in database: OpaquePointer) throws {
        let statement = try prepare(
            "INSERT INTO looks (id, position, payload) VALUES (?, ?, ?)",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        for (position, look) in looks.enumerated() {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bind(look.id.uuidString.lowercased(), at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, sqlite3_int64(position))
            try bind(try encoder.encode(look), at: 3, to: statement)
            try requireDone(statement, in: database)
        }
    }

    private func writeMetadata(key: String, value: Data, in database: OpaquePointer) throws {
        let statement = try prepare(
            "INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        try bind(value, at: 2, to: statement)
        try requireDone(statement, in: database)
    }

    private func readMetadata(key: String, in database: OpaquePointer) throws -> Data? {
        let statement = try prepare("SELECT value FROM metadata WHERE key = ?", in: database)
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw sqliteError(database) }
        return columnData(statement, index: 0)
    }

    private func readRows<Value: Decodable>(
        sql: String,
        as type: Value.Type,
        in database: OpaquePointer
    ) throws -> [Value] {
        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        var values: [Value] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW,
                  let data = columnData(statement, index: 0),
                  let value = try? decoder.decode(Value.self, from: data) else {
                throw result == SQLITE_ROW ? DatabaseError.malformedPayload : sqliteError(database)
            }
            values.append(value)
        }
        return values
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw DatabaseError.sqlite(detail)
        }
    }

    private func integerQuery(_ sql: String, in database: OpaquePointer) throws -> Int32 {
        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError(database) }
        return sqlite3_column_int(statement, 0)
    }

    private func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError(database) }
        return statement
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, Self.transient)
        }
        guard result == SQLITE_OK else { throw DatabaseError.sqlite("Could not bind text value.") }
    }

    private func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), Self.transient)
        }
        guard result == SQLITE_OK else { throw DatabaseError.sqlite("Could not bind data value.") }
    }

    private func requireDone(_ statement: OpaquePointer, in database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
    }

    private func columnData(_ statement: OpaquePointer, index: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count >= 0 else { return nil }
        if count == 0 { return Data() }
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private func sqliteError(_ database: OpaquePointer) -> DatabaseError {
        DatabaseError.sqlite(String(cString: sqlite3_errmsg(database)))
    }

    private func refreshBackup() throws {
        let temporary = backupURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(backupURL.lastPathComponent).tmp-\(UUID().uuidString)")
        try fileManager.copyItem(at: fileURL, to: temporary)
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.moveItem(at: temporary, to: backupURL)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

