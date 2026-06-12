import Foundation
import SQLite3

enum MnemosyneService {
    private static let dbPath = NSHomeDirectory() + "/.hermes/mnemosyne/data/mnemosyne.db"

    private static func openDB() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return nil }
        return db
    }

    static func search(query: String, limit: Int = 30) -> [MemoryItem] {
        guard let db = openDB() else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT wm.* FROM working_memory wm
            JOIN fts_working fts ON wm.id = fts.id
            WHERE fts_working MATCH ?
            ORDER BY wm.importance DESC, wm.timestamp DESC
            LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, query, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var results: [MemoryItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(MemoryItem(row: rowDict(from: stmt)))
        }
        return results
    }

    static func all(limit: Int = 30) -> [MemoryItem] {
        guard let db = openDB() else { return [] }
        defer { sqlite3_close(db) }

        let sql = "SELECT * FROM working_memory ORDER BY importance DESC, timestamp DESC LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var results: [MemoryItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(MemoryItem(row: rowDict(from: stmt)))
        }
        return results
    }

    static func update(id: String, content: String) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }

        let sql = "UPDATE working_memory SET content = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, content, -1, nil)
        sqlite3_bind_text(stmt, 2, id, -1, nil)
        sqlite3_step(stmt)
    }

    static func relevant(to searchText: String, limit: Int = 5) -> [MemoryItem] {
        guard !searchText.isEmpty else { return [] }
        guard let db = openDB() else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT * FROM working_memory
            WHERE content LIKE ?
            ORDER BY importance DESC, timestamp DESC
            LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let pattern = "%\(searchText)%"
        sqlite3_bind_text(stmt, 1, pattern, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var results: [MemoryItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(MemoryItem(row: rowDict(from: stmt)))
        }
        return results
    }

    private static func rowDict(from stmt: OpaquePointer?) -> [String: String] {
        guard let stmt else { return [:] }
        var dict: [String: String] = [:]
        let count = sqlite3_column_count(stmt)
        for i in 0..<count {
            let name = String(cString: sqlite3_column_name(stmt, i))
            let value = sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
            dict[name] = value
        }
        return dict
    }
}
