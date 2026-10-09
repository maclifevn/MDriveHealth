/* Atomic job-UUID receipts, both result types, and recovery history. GPL-3.0-or-later. */
import Foundation
import SQLite3

public struct MeasurementHistoryCursor: Sendable {
    public let createdAt: Date
    public let id: UUID
    public init(createdAt: Date, id: UUID) { self.createdAt = createdAt; self.id = id }
}
extension HistoryStore {
    /// A duplicate UUID with different immutable content is a conflict. A
    /// retry after commit returns the same receipt without another benchmark
    /// row; the pending filesystem record can then be safely acknowledged.
    public func recordMeasurement(_ record: MeasurementJobRecord) throws -> MeasurementHistoryReceipt {
        guard record.intent.historyPolicy != .omit else { throw HistoryError.invalidData("measurement explicitly omits history") }
        try record.validate()
        let data = try MeasurementJournalCoding.encode(record), digest = MeasurementJournalCoding.hash(data)
        let payload = String(decoding: data, as: UTF8.self), id = record.id.uuidString
        return try serialQueue.sync {
            try transaction {
                let select = try prepare("SELECT record_hash,payload FROM measurement_jobs WHERE id=?")
                defer { sqlite3_finalize(select) }; try bindText(select, 1, id)
                let stored: [(String,String)] = try rows(select) { (text($0, 0) ?? "", text($0, 1) ?? "") }
                if let existing = stored.first {
                    guard existing.0 == digest, existing.1 == payload else { throw HistoryError.invalidData("measurement UUID content conflict") }
                    return
                }
                let insert = try prepare("INSERT INTO measurement_jobs(id,drive_key,created_at,record_hash,payload) VALUES(?,?,?,?,?)")
                defer { sqlite3_finalize(insert) }
                try bindText(insert, 1, id); try bindText(insert, 2, record.intent.driveKey)
                try bindDouble(insert, 3, record.intent.createdAt.timeIntervalSince1970); try bindText(insert, 4, digest); try bindText(insert, 5, payload); try done(insert)
                if case .benchmark(let result)? = record.terminal?.outcome { try recordBenchmarkLocked(result, driveKey: record.intent.driveKey) }
            }
            return .init(id: record.id, recordSHA256: digest)
        }
    }
    public func recordMeasurement(_ record: MeasurementJobRecord) async throws -> MeasurementHistoryReceipt {
        try await offMain { try self.recordMeasurement(record) }
    }
    /// Bounded keyset pagination includes archived capacity results and
    /// interrupted attempts, including when their physical drive is offline.
    public func measurementRecords(driveKey: String? = nil, limit: Int = 100, before: MeasurementHistoryCursor? = nil) throws -> [MeasurementJobRecord] {
        guard (1...256).contains(limit) else { throw HistoryError.invalidData("measurement history page limit") }
        if let before { try validateDate(before.createdAt) }
        return try serialQueue.sync {
            var filters: [String] = []
            if driveKey != nil { filters.append("drive_key=?") }
            if before != nil { filters.append("(created_at<? OR (created_at=? AND id<?))") }
            let statement = try prepare("SELECT id,drive_key,created_at,record_hash,payload FROM measurement_jobs" + (filters.isEmpty ? "" : " WHERE " + filters.joined(separator: " AND ")) + " ORDER BY created_at DESC,id DESC LIMIT ?")
            defer { sqlite3_finalize(statement) }; var index: Int32 = 1
            if let driveKey { try bindText(statement, index, driveKey); index += 1 }
            if let before {
                try bindDouble(statement, index, before.createdAt.timeIntervalSince1970); try bindDouble(statement, index + 1, before.createdAt.timeIntervalSince1970)
                try bindText(statement, index + 2, before.id.uuidString); index += 3
            }
            try bindOptionalInt(statement, index, Int64(limit))
            return try rows(statement, decode: decodeMeasurementRecord)
        }
    }
    private func decodeMeasurementRecord(_ row: OpaquePointer?) throws -> MeasurementJobRecord {
        guard let id = text(row, 0), let key = text(row, 1), let digest = text(row, 3), let payload = text(row, 4), payload.utf8.count <= MeasurementJournalCoding.recordLimit else { throw HistoryError.invalidData("measurement history payload") }
        let bytes = Data(payload.utf8)
        guard MeasurementJournalCoding.hash(bytes) == digest else { throw HistoryError.invalidData("measurement history checksum") }
        let record = try JSONDecoder().decode(MeasurementJobRecord.self, from: bytes); try record.validate()
        guard try MeasurementJournalCoding.encode(record) == bytes else { throw HistoryError.invalidData("noncanonical or unknown measurement fields") }
        guard record.id.uuidString == id, record.intent.driveKey == key,
              record.intent.createdAt.timeIntervalSince1970 == (try requiredDouble(row, 2)) else { throw HistoryError.invalidData("measurement history scope") }; return record
    }
    public func measurementRecord(id: UUID) throws -> MeasurementJobRecord? {
        try serialQueue.sync {
            let statement = try prepare("SELECT id,drive_key,created_at,record_hash,payload FROM measurement_jobs WHERE id=?")
            defer { sqlite3_finalize(statement) }; try bindText(statement, 1, id.uuidString)
            return try rows(statement, decode: decodeMeasurementRecord).first
        }
    }
    public func measurementRecord(id: UUID) async throws -> MeasurementJobRecord? {
        try await offMain { try self.measurementRecord(id: id) }
    }
    public func measurementRecords(driveKey: String? = nil, limit: Int = 100, before: MeasurementHistoryCursor? = nil) async throws -> [MeasurementJobRecord] {
        try await offMain { try self.measurementRecords(driveKey: driveKey, limit: limit, before: before) }
    }
}
