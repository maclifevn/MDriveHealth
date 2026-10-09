/*
 * HistoryStore.swift — serialized, versioned SQLite history.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */
import Foundation
import SQLite3

let historyTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct HistoryPoint: Sendable, Codable, Hashable {
    public let capturedAt: Date
    public let temperatureC: Int?
    public let healthScore: Int?
    public let rating: String?
    public let lifetimeLeftPercent: Int?
    public let powerOnHours: UInt64?
    public let bytesWritten: UInt64?
    /// Reported defect/error counters, potentially overlapping or resettable.
    public let defectCount: UInt64?
    public let pendingSectors: UInt64?
}

public enum HistoryError: Error, LocalizedError, Sendable {
    case sqlite(code: Int32, operation: String, message: String)
    case invalidData(String)
    case unsupportedSchema(Int)
    case unavailable
    public var sqliteCode: Int32? {
        if case .sqlite(let code, _, _) = self { return code & 0xff }
        return nil
    }
    public var errorDescription: String? {
        switch self {
        case .sqlite(let code, let operation, let message): return "SQLite \(operation) (\(code)): \(message)"
        case .invalidData(let detail): return "Invalid history data: \(detail)"
        case .unsupportedSchema(let version): return "Unsupported history schema version \(version). The database was not migrated."
        case .unavailable: return "History storage is unavailable"
        }
    }
}

public struct LegacyHistoryCounts: Sendable, Equatable {
    public let snapshots: Int
    public let benchmarks: Int
    public var total: Int { snapshots + benchmarks }
}

public final class HistoryStore: @unchecked Sendable {
    public enum AccessMode: Sendable { case readWrite, readOnly }
    static let schemaVersion = 5
    static let metricsVersion = 2
    private var db: OpaquePointer?
    let serialQueue = DispatchQueue(label: "com.maclife.mdrivehealth.history")
    public let databaseURL: URL
    public private(set) var migrationBackupURL: URL?
    var database: OpaquePointer? { db }

    public static func defaultDatabaseURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("MDriveHealth", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("history.db")
    }

    public init(databaseURL: URL? = nil, accessMode: AccessMode = .readWrite,
                busyTimeoutMilliseconds: Int32 = 3000) throws {
        self.databaseURL = try databaseURL ?? Self.defaultDatabaseURL()
        guard (0...60_000).contains(busyTimeoutMilliseconds) else { throw HistoryError.invalidData("busy timeout") }
        guard self.databaseURL.isFileURL else { throw HistoryError.invalidData("database URL must be a file") }
        // Restrict the new database before WAL/SHM inherit its permissions.
        if accessMode == .readWrite && !FileManager.default.fileExists(atPath: self.databaseURL.path) {
            do {
                try Data().write(to: self.databaseURL, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.databaseURL.path)
            } catch let error as CocoaError where error.code == .fileWriteFileExists { /* Another opener reserved the database. */ }
        }
        let flags = SQLITE_OPEN_FULLMUTEX | (accessMode == .readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let opened = sqlite3_open_v2(self.databaseURL.path, &db, flags, nil)
        guard opened == SQLITE_OK else {
            let error = sqliteError("open", code: opened)
            sqlite3_close(db); db = nil
            throw error
        }
        do {
            try check(sqlite3_extended_result_codes(db, 1), "extended result codes")
            try check(sqlite3_busy_timeout(db, busyTimeoutMilliseconds), "busy timeout")
            try serialQueue.sync {
                let version = try scalarInt("PRAGMA user_version")
                guard version <= Self.schemaVersion else { throw HistoryError.unsupportedSchema(version) }
                guard try scalarText("PRAGMA quick_check(1)") == "ok" else { throw HistoryError.invalidData("database integrity check failed") }
                if accessMode == .readOnly {
                    guard version == Self.schemaVersion else { throw HistoryError.invalidData("read-only database requires migration") }
                    try validateSchema()
                } else {
                    guard try scalarText("PRAGMA journal_mode=WAL").lowercased() == "wal" else { throw HistoryError.invalidData("WAL is unavailable") }
                    try executeLocked("PRAGMA synchronous=FULL")
                    if version < Self.schemaVersion {
                        if try tableExists("drive_snapshots") || tableExists("benchmark_results") {
                            migrationBackupURL = try makeMigrationBackup()
                        }
                        try migrate(from: version)
                    }
                    try validateSchema()
                }
            }
        } catch {
            sqlite3_close(db); db = nil
            throw error
        }
    }
    deinit { sqlite3_close(db) }

    /// Serialize with database work and preserve a live handle if SQLite
    /// refuses to close (for example an unfinished statement).
    public func close() throws {
        try serialQueue.sync {
            guard let db else { return }
            try check(sqlite3_close(db), "close")
            self.db = nil
        }
    }

    /// Compatibility entry point; no model/capacity fallback is considered stable.
    public static func driveKey(for drive: DriveInfo, reading: DriveReading? = nil) -> String {
        DriveIdentity.resolve(for: drive, reading: reading).key
    }

    public func record(driveKey: String, bsdName: String, reading: DriveReading, health: HealthReport) throws {
        try validateDate(reading.capturedAt)
        guard health.score.map({ (0...100).contains($0) }) ?? true,
              health.lifetimeLeftPercent.map({ (0...100).contains($0) }) ?? true else { throw HistoryError.invalidData("health percentage") }
        try serialQueue.sync {
            if let last = try latestLocked(driveKey: driveKey) {
                let elapsed = reading.capturedAt.timeIntervalSince(last.capturedAt)
                if elapsed >= 0 && elapsed < 6 * 3600 && last.temperatureC == reading.temperatureCelsius &&
                    last.healthScore == health.score && last.rating == health.rating.rawValue &&
                    last.lifetimeLeftPercent == health.lifetimeLeftPercent && last.powerOnHours == reading.powerOnHours &&
                    last.bytesWritten == reading.bytesWritten && last.defectCount == reading.defectCount && last.pendingSectors == reading.pendingSectors { return }
            }
            let statement = try prepare("""
                INSERT INTO drive_snapshots (drive_key,bsd_name,captured_at,temperature_c,health_score,rating,
                    lifetime_left,power_on_hours,bytes_written,defect_count,pending_sectors,metrics_version)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,2)
                """)
            defer { sqlite3_finalize(statement) }
            try bindText(statement, 1, driveKey); try bindText(statement, 2, bsdName)
            try bindDouble(statement, 3, reading.capturedAt.timeIntervalSince1970)
            try bindOptionalInt(statement, 4, reading.temperatureCelsius.map(Int64.init))
            try bindOptionalInt(statement, 5, health.score.map(Int64.init)); try bindText(statement, 6, health.rating.rawValue)
            try bindOptionalInt(statement, 7, health.lifetimeLeftPercent.map(Int64.init))
            try bindUInt(statement, 8, reading.powerOnHours); try bindUInt(statement, 9, reading.bytesWritten)
            try bindUInt(statement, 10, reading.defectCount); try bindUInt(statement, 11, reading.pendingSectors)
            try done(statement)
        }
    }

    public func history(driveKey: String, since: Date) throws -> [HistoryPoint] {
        try validateDate(since)
        return try serialQueue.sync {
            let statement = try prepare(Self.snapshotSelect + " WHERE drive_key=? AND captured_at>=? AND metrics_version=2 ORDER BY captured_at,id")
            defer { sqlite3_finalize(statement) }
            try bindText(statement, 1, driveKey); try bindDouble(statement, 2, since.timeIntervalSince1970)
            return try rows(statement, decode: point)
        }
    }
    public func history(driveKey: String, since: Date, bucketInterval: TimeInterval) throws -> [HistoryPoint] {
        guard bucketInterval.isFinite && bucketInterval > 0 else { throw HistoryError.invalidData("bucket interval") }
        guard bucketInterval > 1 else { return try history(driveKey: driveKey, since: since) }
        try validateDate(since)
        return try serialQueue.sync {
            let statement = try prepare("""
                SELECT captured_at,temperature_c,health_score,rating,lifetime_left,power_on_hours,bytes_written,defect_count,pending_sectors
                FROM (SELECT *,ROW_NUMBER() OVER (PARTITION BY CAST(captured_at / ? AS INTEGER)
                    ORDER BY captured_at DESC,id DESC) AS bucket_rank FROM drive_snapshots
                    WHERE drive_key=? AND captured_at>=? AND metrics_version=2)
                WHERE bucket_rank=1 ORDER BY captured_at
                """)
            defer { sqlite3_finalize(statement) }
            try bindDouble(statement, 1, bucketInterval); try bindText(statement, 2, driveKey)
            try bindDouble(statement, 3, since.timeIntervalSince1970)
            return try rows(statement, decode: point)
        }
    }
    public func latest(driveKey: String) throws -> HistoryPoint? { try serialQueue.sync { try latestLocked(driveKey: driveKey) } }
    private func latestLocked(driveKey: String) throws -> HistoryPoint? {
        let statement = try prepare(Self.snapshotSelect + " WHERE drive_key=? AND metrics_version=2 ORDER BY captured_at DESC,id DESC LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, driveKey)
        return try rows(statement, decode: point).first
    }
    public func pruneOlderThan(_ date: Date) throws {
        try validateDate(date)
        try serialQueue.sync {
            try transaction {
                // Legacy data is preserved until the user explicitly archives/removes it.
                for (table, timeColumn, scope) in [("drive_snapshots", "captured_at", "metrics_version=2"), ("benchmark_results", "captured_at", "identity_version=2"), ("measurement_jobs", "created_at", "1=1")] {
                    let statement = try prepare("DELETE FROM \(table) WHERE \(timeColumn)<? AND \(scope)")
                    defer { sqlite3_finalize(statement) }
                    try bindDouble(statement, 1, date.timeIntervalSince1970); try done(statement)
                }
            }
        }
    }
    public func legacyCounts() throws -> LegacyHistoryCounts {
        try serialQueue.sync {
            .init(snapshots: try scalarInt("SELECT COUNT(*) FROM drive_snapshots WHERE metrics_version<2"),
                  benchmarks: try scalarInt("SELECT COUNT(*) FROM benchmark_results WHERE identity_version<2"))
        }
    }

    private static let snapshotSelect = "SELECT captured_at,temperature_c,health_score,rating,lifetime_left,power_on_hours,bytes_written,defect_count,pending_sectors FROM drive_snapshots"
    private func point(_ statement: OpaquePointer?) throws -> HistoryPoint {
        let timestamp = try requiredDouble(statement, 0)
        guard timestamp.isFinite else { throw HistoryError.invalidData("stored timestamp") }
        let score = try optionalInt(statement, 2).map(Int.init), life = try optionalInt(statement, 4).map(Int.init)
        let rating = text(statement, 3)
        guard score.map({ (0...100).contains($0) }) ?? true, life.map({ (0...100).contains($0) }) ?? true,
              rating.map({ HealthRating(rawValue: $0) != nil }) ?? true else { throw HistoryError.invalidData("stored health fields") }
        return .init(capturedAt: Date(timeIntervalSince1970: timestamp), temperatureC: try optionalInt(statement, 1).map(Int.init),
                     healthScore: score, rating: rating, lifetimeLeftPercent: life, powerOnHours: try optionalUInt(statement, 5),
                     bytesWritten: try optionalUInt(statement, 6), defectCount: try optionalUInt(statement, 7), pendingSectors: try optionalUInt(statement, 8))
    }

    // Internal helpers are called only on serialQueue (including initialization).
    func sqliteError(_ operation: String, code: Int32? = nil) -> HistoryError {
        .sqlite(code: code ?? sqlite3_extended_errcode(db), operation: operation,
                message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "database handle unavailable")
    }
    func check(_ code: Int32, _ operation: String) throws { guard code == SQLITE_OK else { throw sqliteError(operation, code: code) } }
    func prepare(_ sql: String) throws -> OpaquePointer? {
        guard db != nil else { throw HistoryError.unavailable }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK else { sqlite3_finalize(statement); throw sqliteError("prepare", code: code) }
        return statement
    }
    func done(_ statement: OpaquePointer?) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw sqliteError("step write", code: code) }
    }
    /// A partial result must never hide the error at the end of the statement.
    func rows<T>(_ statement: OpaquePointer?, step: (OpaquePointer?) -> Int32 = sqlite3_step,
                 decode: (OpaquePointer?) throws -> T) throws -> [T] {
        var values: [T] = []
        while true {
            let code = step(statement)
            switch code {
            case SQLITE_ROW: values.append(try decode(statement))
            case SQLITE_DONE: return values
            default: throw sqliteError("step read", code: code)
            }
        }
    }
    func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) throws {
        guard value.utf8.count <= Int(Int32.max) else { throw HistoryError.invalidData("text too large") }
        try check(sqlite3_bind_text(statement, index, value, Int32(value.utf8.count), historyTransient), "bind text")
    }
    func bindDouble(_ statement: OpaquePointer?, _ index: Int32, _ value: Double?) throws {
        guard let value else { try check(sqlite3_bind_null(statement, index), "bind null"); return }
        guard value.isFinite else { throw HistoryError.invalidData("nonfinite number") }
        try check(sqlite3_bind_double(statement, index, value), "bind number")
    }
    func bindOptionalInt(_ statement: OpaquePointer?, _ index: Int32, _ value: Int64?) throws {
        try check(value.map { sqlite3_bind_int64(statement, index, $0) } ?? sqlite3_bind_null(statement, index), "bind integer")
    }
    func bindUInt(_ statement: OpaquePointer?, _ index: Int32, _ value: UInt64?) throws {
        if let value { try bindText(statement, index, String(value)) }
        else { try check(sqlite3_bind_null(statement, index), "bind null") }
    }
    func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, index) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
    }
    func optionalInt(_ statement: OpaquePointer?, _ index: Int32) throws -> Int64? {
        let type = sqlite3_column_type(statement, index)
        if type == SQLITE_NULL { return nil }
        guard type == SQLITE_INTEGER else { throw HistoryError.invalidData("stored integer type") }
        return sqlite3_column_int64(statement, index)
    }
    func optionalDouble(_ statement: OpaquePointer?, _ index: Int32) throws -> Double? {
        let type = sqlite3_column_type(statement, index)
        if type == SQLITE_NULL { return nil }
        guard type == SQLITE_INTEGER || type == SQLITE_FLOAT else { throw HistoryError.invalidData("stored numeric type") }
        let value = sqlite3_column_double(statement, index)
        guard value.isFinite else { throw HistoryError.invalidData("stored nonfinite number") }
        return value
    }
    func requiredDouble(_ statement: OpaquePointer?, _ index: Int32) throws -> Double {
        guard let value = try optionalDouble(statement, index) else { throw HistoryError.invalidData("missing stored number") }
        return value
    }
    func optionalUInt(_ statement: OpaquePointer?, _ index: Int32) throws -> UInt64? {
        guard let value = text(statement, index) else { return nil }
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT, let number = UInt64(value), String(number) == value else { throw HistoryError.invalidData("stored unsigned counter") }
        return number
    }
    func validateDate(_ date: Date) throws { guard date.timeIntervalSince1970.isFinite else { throw HistoryError.invalidData("timestamp") } }
    func executeLocked(_ sql: String) throws {
        guard db != nil else { throw HistoryError.unavailable }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard code == SQLITE_OK else { throw sqliteError("execute", code: code) }
    }
    func scalarText(_ sql: String) throws -> String {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        let values: [String] = try rows(statement) { text($0, 0) ?? "" }
        guard let value = values.first else { throw HistoryError.invalidData("missing scalar result") }
        return value
    }
    func scalarInt(_ sql: String) throws -> Int {
        guard let value = Int(try scalarText(sql)) else { throw HistoryError.invalidData("noninteger scalar") }
        return value
    }
    func transaction(_ work: () throws -> Void) throws {
        try executeLocked("BEGIN IMMEDIATE")
        do { try work(); try executeLocked("COMMIT") }
        catch {
            // Preserve the original error, and explicitly report rollback failure.
            do { try executeLocked("ROLLBACK") } catch let rollbackError {
                throw HistoryError.invalidData("transaction failed: \(error.localizedDescription); rollback failed: \(rollbackError.localizedDescription)")
            }
            throw error
        }
    }
}
