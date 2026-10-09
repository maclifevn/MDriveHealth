/*
 * HistoryStore+Async.swift — async overloads so UI code never blocks the
 * main thread on sqlite. Each hops to a utility queue and runs the matching
 * synchronous API (the closure context is synchronous, so the sync overload
 * resolves — no recursion).
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

extension HistoryStore {
    public func close() async throws { try await offMain { try self.close() } }

    func offMain<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    public func record(driveKey: String, bsdName: String, reading: DriveReading, health: HealthReport) async throws {
        try await offMain { try self.record(driveKey: driveKey, bsdName: bsdName, reading: reading, health: health) }
    }

    public func history(driveKey: String, since: Date) async throws -> [HistoryPoint] {
        try await offMain { try self.history(driveKey: driveKey, since: since) }
    }

    public func history(driveKey: String, since: Date,
                        bucketInterval: TimeInterval) async throws -> [HistoryPoint] {
        try await offMain {
            try self.history(driveKey: driveKey, since: since,
                             bucketInterval: bucketInterval)
        }
    }

    public func latest(driveKey: String) async throws -> HistoryPoint? {
        try await offMain { try self.latest(driveKey: driveKey) }
    }

    public func benchmarks(driveKey: String, since: Date) async throws -> [BenchmarkResult] {
        try await offMain { try self.benchmarks(driveKey: driveKey, since: since) }
    }

    public func latestBenchmark(driveKey: String) async throws -> BenchmarkResult? {
        try await offMain { try self.latestBenchmark(driveKey: driveKey) }
    }

    public func record(benchmark result: BenchmarkResult, driveKey: String) async throws {
        try await offMain { try self.record(benchmark: result, driveKey: driveKey) }
    }

    public func pruneOlderThan(_ date: Date) async throws {
        try await offMain { try self.pruneOlderThan(date) }
    }
}
