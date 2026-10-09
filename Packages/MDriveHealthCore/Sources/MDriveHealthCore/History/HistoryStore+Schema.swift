/*
 * History schema migrations preserve legacy records and take a consistent backup.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */
import Foundation
import SQLite3

extension HistoryStore {
    private static func snapshotsSchema(_ table: String) -> String {
        """
        CREATE TABLE \(table) (
            id INTEGER PRIMARY KEY AUTOINCREMENT,drive_key TEXT NOT NULL,bsd_name TEXT,
            captured_at REAL NOT NULL,temperature_c INTEGER,health_score INTEGER,rating TEXT,
            lifetime_left INTEGER,power_on_hours TEXT,bytes_written TEXT,defect_count TEXT,pending_sectors TEXT,
            metrics_version INTEGER NOT NULL DEFAULT 2)
        """
    }
    private static func benchmarksSchema(_ table: String) -> String {
        """
        CREATE TABLE \(table) (
            id INTEGER PRIMARY KEY AUTOINCREMENT,drive_key TEXT NOT NULL,bsd_name TEXT,volume_name TEXT,
            mount_point TEXT,captured_at REAL NOT NULL,file_size TEXT NOT NULL,seq_block INTEGER NOT NULL,
            rand_block INTEGER NOT NULL,seq_write_bps REAL NOT NULL,seq_read_bps REAL NOT NULL,
            rand_write_bps REAL,rand_read_bps REAL,queue_depth INTEGER NOT NULL DEFAULT 1,
            identity_version INTEGER NOT NULL DEFAULT 2)
        """
    }
    func tableExists(_ table: String) throws -> Bool {
        let statement = try prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, table)
        return try !rows(statement) { text($0, 0) ?? "" }.isEmpty
    }
    func columns(_ table: String) throws -> [String: String] {
        // table is always an internal schema identifier, never user input.
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        let entries: [(String, String)] = try rows(statement) { (text($0, 1) ?? "", text($0, 2)?.uppercased() ?? "") }
        return Dictionary(entries, uniquingKeysWith: { first, _ in first })
    }
    private func requireColumns(_ names: Set<String>, in table: String) throws {
        guard names.isSubset(of: Set(try columns(table).keys)) else { throw HistoryError.invalidData("unexpected schema for \(table)") }
    }
    private func requirePrimaryKey(_ name: String, in table: String) throws {
        let statement = try prepare("PRAGMA table_info(\(table))"); defer { sqlite3_finalize(statement) }
        let keys: [(String,Int64)] = try rows(statement) { row in
            (text(row, 1) ?? "", try optionalInt(row, 5) ?? 0)
        }.filter { $0.1 > 0 }
        guard keys.count == 1, keys[0].0 == name, keys[0].1 == 1 else { throw HistoryError.invalidData("unexpected primary key for \(table)") }
    }
    func validateSchema() throws {
        try requireColumns(["id","drive_key","bsd_name","captured_at","temperature_c","health_score","rating","lifetime_left","power_on_hours","bytes_written","defect_count","pending_sectors","metrics_version"], in: "drive_snapshots")
        try requireColumns(["id","drive_key","bsd_name","volume_name","mount_point","captured_at","file_size","seq_block","rand_block","seq_write_bps","seq_read_bps","rand_write_bps","rand_read_bps","queue_depth","identity_version"], in: "benchmark_results")
        let snapshots = try columns("drive_snapshots"), benchmarks = try columns("benchmark_results")
        guard ["power_on_hours","bytes_written","defect_count","pending_sectors"].allSatisfy({ snapshots[$0] == "TEXT" }), benchmarks["file_size"] == "TEXT" else {
            throw HistoryError.invalidData("counter column affinity must be TEXT")
        }
        try requireColumns(["drive_key","revision","state"], in: "self_test_tracking")
        try requireColumns(["id","drive_key","created_at","event","delivery_state"], in: "self_test_events")
        let tracking = try columns("self_test_tracking"), events = try columns("self_test_events")
        guard tracking["drive_key"] == "TEXT", tracking["revision"] == "INTEGER", tracking["state"] == "TEXT",
              events["id"] == "TEXT", events["drive_key"] == "TEXT", events["created_at"] == "REAL",
              events["event"] == "TEXT", events["delivery_state"] == "TEXT" else {
            throw HistoryError.invalidData("self-test column affinity")
        }
        try requirePrimaryKey("drive_key", in: "self_test_tracking")
        try requirePrimaryKey("id", in: "self_test_events")
        try requireColumns(["id","drive_key","created_at","record_hash","payload"], in: "measurement_jobs")
        let measurements = try columns("measurement_jobs")
        guard measurements["id"] == "TEXT", measurements["drive_key"] == "TEXT", measurements["created_at"] == "REAL",
              measurements["record_hash"] == "TEXT", measurements["payload"] == "TEXT" else { throw HistoryError.invalidData("measurement column affinity") }
        try requirePrimaryKey("id", in: "measurement_jobs")
    }
    func migrate(from version: Int) throws {
        try transaction {
            if version < 3 {
                if try tableExists("drive_snapshots") {
                    try requireColumns(["id","drive_key","bsd_name","captured_at","temperature_c","health_score","rating","lifetime_left","power_on_hours","bytes_written","defect_count","pending_sectors"], in: "drive_snapshots")
                    let originalColumns = try columns("drive_snapshots")
                    try executeLocked(Self.snapshotsSchema("_md_snapshots_v3"))
                    let metrics = originalColumns["metrics_version"] == nil ? "1" : "metrics_version"
                    try executeLocked("""
                        INSERT INTO _md_snapshots_v3 SELECT id,drive_key,bsd_name,captured_at,temperature_c,health_score,rating,lifetime_left,
                            CAST(power_on_hours AS TEXT),CAST(bytes_written AS TEXT),CAST(defect_count AS TEXT),CAST(pending_sectors AS TEXT),\(metrics)
                        FROM drive_snapshots
                        """)
                    try executeLocked("DROP TABLE drive_snapshots; ALTER TABLE _md_snapshots_v3 RENAME TO drive_snapshots")
                } else { try executeLocked(Self.snapshotsSchema("drive_snapshots")) }
                if try tableExists("benchmark_results") {
                    try requireColumns(["id","drive_key","bsd_name","volume_name","mount_point","captured_at","file_size","seq_block","rand_block","seq_write_bps","seq_read_bps","rand_write_bps","rand_read_bps"], in: "benchmark_results")
                    let originalColumns = try columns("benchmark_results")
                    try executeLocked(Self.benchmarksSchema("_md_benchmarks_v3"))
                    let depth = originalColumns["queue_depth"] == nil ? "1" : "queue_depth"
                    let identity = originalColumns["identity_version"] == nil ? "1" : "identity_version"
                    try executeLocked("""
                        INSERT INTO _md_benchmarks_v3 SELECT id,drive_key,bsd_name,volume_name,mount_point,captured_at,
                            CAST(file_size AS TEXT),seq_block,rand_block,seq_write_bps,seq_read_bps,rand_write_bps,rand_read_bps,\(depth),\(identity)
                        FROM benchmark_results
                        """)
                    try executeLocked("DROP TABLE benchmark_results; ALTER TABLE _md_benchmarks_v3 RENAME TO benchmark_results")
                } else { try executeLocked(Self.benchmarksSchema("benchmark_results")) }
                try executeLocked("""
                    CREATE INDEX idx_snapshots_drive_time ON drive_snapshots(drive_key,captured_at);
                    CREATE INDEX idx_snapshots_time ON drive_snapshots(captured_at);
                    CREATE INDEX idx_benchmarks_drive_time ON benchmark_results(drive_key,captured_at);
                    """)
            }
            if version < 4 {
            try executeLocked("""
                CREATE TABLE self_test_tracking (drive_key TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL CHECK(revision>0), state TEXT NOT NULL);
                CREATE TABLE self_test_events (id TEXT PRIMARY KEY NOT NULL, drive_key TEXT NOT NULL, created_at REAL NOT NULL, event TEXT NOT NULL,
                    delivery_state TEXT NOT NULL CHECK(delivery_state IN ('pending','sending','delivered','suppressed','uncertain')));
                CREATE INDEX idx_self_test_events_delivery ON self_test_events(delivery_state,created_at);
                """)
            }
            if version < 5 {
                try executeLocked("""
                    CREATE TABLE measurement_jobs (id TEXT PRIMARY KEY NOT NULL, drive_key TEXT NOT NULL,
                        created_at REAL NOT NULL, record_hash TEXT NOT NULL, payload TEXT NOT NULL);
                    CREATE INDEX idx_measurement_jobs_drive_time ON measurement_jobs(drive_key,created_at,id);
                    CREATE INDEX idx_measurement_jobs_time ON measurement_jobs(created_at,id);
                    """)
            }
            try executeLocked("PRAGMA user_version=5")
            try validateSchema()
        }
    }
    func makeMigrationBackup() throws -> URL {
        let destination = databaseURL.deletingLastPathComponent().appendingPathComponent(databaseURL.lastPathComponent + ".migration-\(UUID().uuidString).backup")
        // Reserve a fresh file; never replace an existing recovery copy.
        try Data().write(to: destination, options: .withoutOverwriting)
        let reserved = try FileManager.default.attributesOfItem(atPath: destination.path)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            var target: OpaquePointer?
            guard sqlite3_open_v2(destination.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                let message = target.map { String(cString: sqlite3_errmsg($0)) } ?? "backup handle unavailable"
                sqlite3_close(target)
                throw HistoryError.invalidData("backup open: \(message)")
            }
            defer { sqlite3_close(target) }
            guard let backup = sqlite3_backup_init(target, "main", database, "main") else { throw HistoryError.invalidData("backup initialization failed") }
            let result = sqlite3_backup_step(backup, -1)
            let finish = sqlite3_backup_finish(backup)
            guard result == SQLITE_DONE, finish == SQLITE_OK else { throw HistoryError.sqlite(code: result == SQLITE_DONE ? finish : result, operation: "migration backup", message: String(cString: sqlite3_errmsg(target))) }
            return destination
        } catch {
            let original = error
            do {
                let current = try FileManager.default.attributesOfItem(atPath: destination.path)
                guard current[.systemNumber] as? NSNumber == reserved[.systemNumber] as? NSNumber,
                      current[.systemFileNumber] as? NSNumber == reserved[.systemFileNumber] as? NSNumber,
                      current[.ownerAccountID] as? NSNumber == reserved[.ownerAccountID] as? NSNumber else {
                    throw HistoryError.invalidData("incomplete backup ownership changed; file left untouched")
                }
                try FileManager.default.removeItem(at: destination)
            } catch let cleanupError {
                throw HistoryError.invalidData("backup failed: \(original.localizedDescription); incomplete backup cleanup failed: \(cleanupError.localizedDescription)")
            }
            throw original
        }
    }
}
