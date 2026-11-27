import Foundation
import SQLite3

actor TrainingStore {
    private let url: URL
    private var connection: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) { self.url = url }
    deinit { if let connection { sqlite3_close(connection) } }

    func load(reset: Bool = false) throws -> Training? {
        let database = try open()
        if reset {
            try execute("BEGIN IMMEDIATE", database)
            do {
                try execute("DELETE FROM session; DELETE FROM attempts", database)
                try execute("COMMIT", database)
            } catch {
                try? execute("ROLLBACK", database)
                throw error
            }
        }
        var state: Training?
        try read("SELECT value FROM session WHERE id = 1", database) { bytes in
            state = try JSONDecoder().decode(Training.self, from: bytes)
        }
        if var restored = state {
            try read("SELECT value FROM attempts ORDER BY rowid", database) { bytes in
                restored.attempts.append(try JSONDecoder().decode(Attempt.self, from: bytes))
            }
            return restored
        }
        return nil
    }

    func save(_ training: Training, adding attempts: [Attempt] = []) throws {
        let database = try open()
        var snapshot = training
        snapshot.attempts = []
        let encoder = JSONEncoder()
        try execute("BEGIN IMMEDIATE", database)
        do {
            for attempt in attempts {
                try write("INSERT INTO attempts(id,value) VALUES(?,?)", database, key: attempt.id, value: encoder.encode(attempt))
            }
            try write("INSERT OR REPLACE INTO session(id,value) VALUES(1,?)", database, value: encoder.encode(snapshot))
            try execute("COMMIT", database)
        } catch {
            try? execute("ROLLBACK", database)
            throw error
        }
    }

    private func open() throws -> OpaquePointer {
        if let connection { return connection }
        var folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let database = handle else {
            if let handle { sqlite3_close(handle) }
            throw Failure.database
        }
        do {
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS session(id INTEGER PRIMARY KEY CHECK(id=1), value BLOB NOT NULL); CREATE TABLE IF NOT EXISTS attempts(id TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL);", database)
            connection = database
            return database
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    private func execute(_ sql: String, _ database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.database }
    }

    private func statement(_ sql: String, _ database: OpaquePointer) throws -> OpaquePointer {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw Failure.database }
        return prepared
    }

    private func read(_ sql: String, _ database: OpaquePointer, consume: (Data) throws -> Void) throws {
        let query = try statement(sql, database)
        defer { sqlite3_finalize(query) }
        while true {
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW, let pointer = sqlite3_column_blob(query, 0) else { throw Failure.database }
            try consume(Data(bytes: pointer, count: Int(sqlite3_column_bytes(query, 0))))
        }
    }

    private func write(_ sql: String, _ database: OpaquePointer, key: String? = nil, value: Data) throws {
        let query = try statement(sql, database)
        defer { sqlite3_finalize(query) }
        if let key {
            guard key.withCString({ sqlite3_bind_text(query, 1, $0, -1, transient) }) == SQLITE_OK else { throw Failure.database }
        }
        let result = value.withUnsafeBytes { sqlite3_bind_blob(query, key == nil ? 1 : 2, $0.baseAddress, Int32($0.count), transient) }
        guard result == SQLITE_OK, sqlite3_step(query) == SQLITE_DONE else { throw Failure.database }
    }

    enum Failure: Error { case database }
}
