import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct DatabaseError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// One row of a result set. Only valid inside the mapping closure.
public struct Row {
    fileprivate let stmt: OpaquePointer
    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func optInt(_ i: Int32) -> Int64? { isNull(i) ? nil : int(i) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func optDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
    public func text(_ i: Int32) -> String { optText(i) ?? "" }
    public func optText(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
    public func blob(_ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
}

/// A single SQLite connection. Not thread-safe on its own; `Database` serialises access.
public final class Connection {
    fileprivate var handle: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw DatabaseError(message: "Could not open database at \(path)")
        }
        // secure_delete: deleted rows are overwritten with zeros (matters when photos move into Private Space).
        try exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL; PRAGMA secure_delete=ON;")
    }

    deinit { sqlite3_close_v2(handle) }

    private var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw DatabaseError(message: msg)
        }
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError(message: "\(lastError) — in: \(sql)")
        }
        for (offset, arg) in args.enumerated() {
            let i = Int32(offset + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, i)
            case let v as Int: sqlite3_bind_int64(stmt, i, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, i, v)
            case let v as Int32: sqlite3_bind_int64(stmt, i, Int64(v))
            case let v as Bool: sqlite3_bind_int64(stmt, i, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(stmt, i, v)
            case let v as Float: sqlite3_bind_double(stmt, i, Double(v))
            case let v as Date: sqlite3_bind_double(stmt, i, v.timeIntervalSince1970)
            case let v as String: sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT)
            case let v as Data:
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            default:
                sqlite3_finalize(stmt)
                throw DatabaseError(message: "Unsupported bind type \(type(of: arg))")
            }
        }
        return stmt
    }

    @discardableResult
    public func run(_ sql: String, _ args: Any?...) throws -> Int64 {
        try run(sql, args: args)
    }

    @discardableResult
    public func run(_ sql: String, args: [Any?]) throws -> Int64 {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DatabaseError(message: "\(lastError) — in: \(sql)") }
        return sqlite3_last_insert_rowid(handle)
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }

    public func query<T>(_ sql: String, _ args: [Any?] = [], _ map: (Row) throws -> T) throws -> [T] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DatabaseError(message: "\(lastError) — in: \(sql)") }
            out.append(try map(Row(stmt: stmt)))
        }
        return out
    }

    public func scalar(_ sql: String, _ args: [Any?] = []) throws -> Int64 {
        try query(sql, args) { $0.int(0) }.first ?? 0
    }

    /// Online backup of this database into a new file (safe while the app is using it).
    func backup(to url: URL) throws {
        var dest: OpaquePointer?
        guard sqlite3_open(url.path, &dest) == SQLITE_OK else { throw DatabaseError(message: "Cannot create backup file") }
        defer { sqlite3_close(dest) }
        guard let b = sqlite3_backup_init(dest, "main", handle, "main") else {
            throw DatabaseError(message: String(cString: sqlite3_errmsg(dest)))
        }
        sqlite3_backup_step(b, -1)
        guard sqlite3_backup_finish(b) == SQLITE_OK else { throw DatabaseError(message: String(cString: sqlite3_errmsg(dest))) }
    }
}

/// Thread-safe database: all access goes through one serial queue.
public final class Database: @unchecked Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "pixora.database")
    private var conn: Connection

    public init(url: URL) throws {
        self.url = url
        conn = try Connection(path: url.path)
        try queue.sync { try Schema.migrate(conn) }
    }

    public func read<T>(_ body: (Connection) throws -> T) throws -> T {
        try queue.sync { try body(conn) }
    }

    @discardableResult
    public func write<T>(_ body: (Connection) throws -> T) throws -> T {
        try queue.sync {
            try conn.exec("BEGIN IMMEDIATE")
            do {
                let result = try body(conn)
                try conn.exec("COMMIT")
                return result
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    public func backup(to url: URL) throws {
        try queue.sync { try conn.backup(to: url) }
    }

    /// Replace the live database with a backup file after checking it is a Pixora library.
    public func restore(from backupURL: URL) throws {
        let probe = try Connection(path: backupURL.path)
        let version = try probe.query("SELECT value FROM meta WHERE key='schema'") { $0.text(0) }.first
        guard version != nil else { throw DatabaseError(message: "That file is not a Pixora people-database backup.") }
        try queue.sync {
            conn = try Connection(path: ":memory:")  // release the file before replacing it
            let fm = FileManager.default
            for suffix in ["", "-wal", "-shm"] {
                try? fm.removeItem(atPath: url.path + suffix)
            }
            try fm.copyItem(at: backupURL, to: url)
            conn = try Connection(path: url.path)
            try Schema.migrate(conn)
        }
    }
}

enum Schema {
    static let version = 1

    static func migrate(_ c: Connection) throws {
        try c.exec("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS sources(
            id INTEGER PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL, bookmark BLOB,
            volume_uuid TEXT, volume_name TEXT, volume_rel TEXT, is_removable INTEGER NOT NULL DEFAULT 0,
            added_at REAL NOT NULL, last_scan_at REAL);
        CREATE TABLE IF NOT EXISTS imports(
            id INTEGER PRIMARY KEY, source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            started_at REAL NOT NULL, finished_at REAL, status TEXT NOT NULL,
            files_total INTEGER NOT NULL DEFAULT 0, files_new INTEGER NOT NULL DEFAULT 0,
            files_skipped INTEGER NOT NULL DEFAULT 0, faces_found INTEGER NOT NULL DEFAULT 0,
            errors INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS photos(
            id INTEGER PRIMARY KEY, source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            rel_path TEXT NOT NULL, filename TEXT NOT NULL, ext TEXT NOT NULL, siblings TEXT,
            file_size INTEGER NOT NULL, mtime REAL NOT NULL, fingerprint TEXT,
            width INTEGER, height INTEGER, taken_at REAL, camera TEXT, lens TEXT, rating INTEGER,
            scan_state INTEGER NOT NULL DEFAULT 0, scan_error TEXT, embedder TEXT,
            import_id INTEGER, added_at REAL NOT NULL,
            UNIQUE(source_id, rel_path));
        CREATE INDEX IF NOT EXISTS photos_fingerprint ON photos(fingerprint);
        CREATE TABLE IF NOT EXISTS people(
            id INTEGER PRIMARY KEY, name TEXT, cover_face_id INTEGER, created_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS faces(
            id INTEGER PRIMARY KEY, photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
            x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL,
            pixel_size REAL NOT NULL DEFAULT 0, quality REAL, embedding BLOB, embedder TEXT,
            person_id INTEGER REFERENCES people(id) ON DELETE SET NULL,
            state INTEGER NOT NULL DEFAULT 0, score REAL, thumb BLOB, created_at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS faces_person ON faces(person_id, state);
        CREATE INDEX IF NOT EXISTS faces_photo ON faces(photo_id);
        CREATE TABLE IF NOT EXISTS rejections(
            face_id INTEGER NOT NULL REFERENCES faces(id) ON DELETE CASCADE,
            person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
            PRIMARY KEY(face_id, person_id));
        INSERT OR IGNORE INTO meta(key, value) VALUES('schema', '\(version)');
        """)
        // v2 — added in place so existing libraries keep their data.
        try addColumn(c, "faces", "sharpness", "REAL")
        try addColumn(c, "faces", "eye_ratio", "REAL")
        try addColumn(c, "faces", "enriched", "INTEGER NOT NULL DEFAULT 0")
        try addColumn(c, "photos", "print", "BLOB")
        try addColumn(c, "photos", "burst_id", "INTEGER")
        try addColumn(c, "photos", "enriched", "INTEGER NOT NULL DEFAULT 0")
        try addColumn(c, "people", "contact_id", "TEXT")
        try addColumn(c, "people", "contact_handles", "TEXT")
        try c.exec("CREATE INDEX IF NOT EXISTS photos_burst ON photos(burst_id)")
        // v3 — Private Space.
        try addColumn(c, "people", "is_private", "INTEGER NOT NULL DEFAULT 0")
        try addColumn(c, "people", "name_enc", "BLOB")
        try c.exec("""
        CREATE TABLE IF NOT EXISTS private_items(uuid TEXT PRIMARY KEY, path_token TEXT, fp_token TEXT, created_at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS private_items_path ON private_items(path_token);
        CREATE INDEX IF NOT EXISTS private_items_fp ON private_items(fp_token);
        CREATE TABLE IF NOT EXISTS private_refs(person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE, embedder TEXT, blob BLOB NOT NULL);
        """)
        // v4 — favorites (slideshows).
        try c.exec("CREATE TABLE IF NOT EXISTS favorites(photo_id INTEGER PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE, added_at REAL NOT NULL)")
    }

    private static func addColumn(_ c: Connection, _ table: String, _ column: String, _ decl: String) throws {
        let cols = try c.query("PRAGMA table_info(\(table))") { $0.text(1) }
        if !cols.contains(column) { try c.exec("ALTER TABLE \(table) ADD COLUMN \(column) \(decl)") }
    }
}
