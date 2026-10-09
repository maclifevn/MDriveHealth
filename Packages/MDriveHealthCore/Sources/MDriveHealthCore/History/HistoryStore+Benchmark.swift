/* Benchmark persistence. This file is part of MDriveHealth, GPL-3.0-or-later. */
import Foundation
import SQLite3

extension HistoryStore {
    public func record(benchmark result: BenchmarkResult, driveKey: String) throws {
        try serialQueue.sync { try recordBenchmarkLocked(result, driveKey: driveKey) }
    }
    // Shared by the UUID receipt transaction; never recursively enter the queue.
    func recordBenchmarkLocked(_ result: BenchmarkResult, driveKey: String) throws {
        try validateDate(result.capturedAt)
        guard result.fileSizeBytes > 0, result.sequentialBlockBytes > 0, result.randomBlockBytes > 0, result.queueDepth > 0,
              [result.sequentialWriteBytesPerSec,result.sequentialReadBytesPerSec].allSatisfy({ $0.isFinite && $0 >= 0 }),
              [result.randomWriteBytesPerSec,result.randomReadBytesPerSec].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw HistoryError.invalidData("benchmark fields") }
        let statement = try prepare("""
            INSERT INTO benchmark_results (drive_key,bsd_name,volume_name,mount_point,captured_at,file_size,seq_block,rand_block,
                seq_write_bps,seq_read_bps,rand_write_bps,rand_read_bps,queue_depth,identity_version) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,2)
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, driveKey); try bindText(statement, 2, result.volumeBSDName)
        try bindText(statement, 3, result.volumeName); try bindText(statement, 4, result.mountPoint)
        try bindDouble(statement, 5, result.capturedAt.timeIntervalSince1970); try bindUInt(statement, 6, result.fileSizeBytes)
        try bindOptionalInt(statement, 7, Int64(result.sequentialBlockBytes)); try bindOptionalInt(statement, 8, Int64(result.randomBlockBytes))
        try bindDouble(statement, 9, result.sequentialWriteBytesPerSec); try bindDouble(statement, 10, result.sequentialReadBytesPerSec)
        try bindDouble(statement, 11, result.randomWriteBytesPerSec); try bindDouble(statement, 12, result.randomReadBytesPerSec)
        try bindOptionalInt(statement, 13, Int64(result.queueDepth)); try done(statement)
    }
    public func latestBenchmark(driveKey: String) throws -> BenchmarkResult? {
        try serialQueue.sync {
            let statement = try prepare(Self.benchmarkSelect + " WHERE drive_key=? AND identity_version=2 ORDER BY captured_at DESC,id DESC LIMIT 1")
            defer { sqlite3_finalize(statement) }
            try bindText(statement, 1, driveKey)
            return try rows(statement, decode: benchmarkResult).first
        }
    }
    public func benchmarks(driveKey: String, since: Date) throws -> [BenchmarkResult] {
        try validateDate(since)
        return try serialQueue.sync {
            let statement = try prepare(Self.benchmarkSelect + " WHERE drive_key=? AND captured_at>=? AND identity_version=2 ORDER BY captured_at,id")
            defer { sqlite3_finalize(statement) }
            try bindText(statement, 1, driveKey); try bindDouble(statement, 2, since.timeIntervalSince1970)
            return try rows(statement, decode: benchmarkResult)
        }
    }
    private static let benchmarkSelect = "SELECT bsd_name,volume_name,mount_point,captured_at,file_size,seq_block,rand_block,seq_write_bps,seq_read_bps,rand_write_bps,rand_read_bps,queue_depth FROM benchmark_results"
    private func benchmarkResult(_ statement: OpaquePointer?) throws -> BenchmarkResult {
        let timestamp = try requiredDouble(statement, 3), fileSize = try optionalUInt(statement, 4)
        let seqBlock = Int(try optionalInt(statement, 5) ?? 0), randBlock = Int(try optionalInt(statement, 6) ?? 0), depth = Int(try optionalInt(statement, 11) ?? 0)
        let write = try requiredDouble(statement, 7), read = try requiredDouble(statement, 8)
        let randWrite = try optionalDouble(statement, 9)
        let randRead = try optionalDouble(statement, 10)
        guard timestamp.isFinite, let fileSize, fileSize > 0, seqBlock > 0, randBlock > 0, depth > 0,
              [write,read].allSatisfy({ $0.isFinite && $0 >= 0 }), [randWrite,randRead].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw HistoryError.invalidData("stored benchmark") }
        return .init(capturedAt: Date(timeIntervalSince1970: timestamp),volumeBSDName: text(statement, 0) ?? "",
                     volumeName: text(statement, 1) ?? "",mountPoint: text(statement, 2) ?? "",fileSizeBytes: fileSize,
                     sequentialBlockBytes: seqBlock,randomBlockBytes: randBlock,queueDepth: depth,
                     sequentialWriteBytesPerSec: write,sequentialReadBytesPerSec: read,
                     randomWriteBytesPerSec: randWrite,randomReadBytesPerSec: randRead)
    }
}
