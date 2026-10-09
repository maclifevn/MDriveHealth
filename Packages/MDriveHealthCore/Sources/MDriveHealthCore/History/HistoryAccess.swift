/*
 * HistoryAccess.swift — observable storage availability and operation failures.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */
import Foundation
import Observation

public struct HistoryOperationIssue: Sendable, Identifiable, Equatable {
    public let id: String
    public let message: String
}

@MainActor @Observable
public final class HistoryAccess {
    public enum State: Sendable, Equatable { case idle, opening, ready, unavailable, closing, closed }
    public private(set) var state: State = .idle
    public private(set) var issues: [String: HistoryOperationIssue] = [:]
    public private(set) var legacyCounts = LegacyHistoryCounts(snapshots: 0, benchmarks: 0)
    public private(set) var migrationBackupURL: URL?
    public var isDegraded: Bool { state == .unavailable || !issues.isEmpty }
    public var firstIssue: HistoryOperationIssue? { issues.values.sorted { $0.id < $1.id }.first }
    @ObservationIgnored private var store: HistoryStore?
    @ObservationIgnored private let factory: @Sendable () throws -> HistoryStore
    @ObservationIgnored private var connecting: Task<Void, Error>?
    @ObservationIgnored private var closing: Task<Void, Error>?
    @ObservationIgnored private var activeRuns = 0
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var acceptsWork = true
    private struct Connection: Sendable { let store: HistoryStore; let legacy: LegacyHistoryCounts }

    public init(factory: @escaping @Sendable () throws -> HistoryStore = { try HistoryStore() }) { self.factory = factory }
    public func connect(retry: Bool = false) async throws {
        guard acceptsWork else { throw HistoryError.unavailable }
        if let connecting { try await connecting.value; return }
        if store != nil && !retry { return }
        if state == .unavailable && !retry { throw HistoryError.unavailable }
        state = .opening
        let factory = factory
        // Only the shared opening task installs the connection. Awaiting
        // callers cannot reinstall an old handle after a newer retry finishes.
        let task = Task { @MainActor in
            defer { connecting = nil }
            do {
                let connection = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Connection, Error>) in
                    DispatchQueue.global(qos: .utility).async {
                        continuation.resume(with: Result {
                            let store = try factory()
                            return Connection(store: store, legacy: try store.legacyCounts())
                        })
                    }
                }
                install(connection)
            } catch {
                store = nil; state = .unavailable; report(error, operation: "open")
                throw error
            }
        }
        connecting = task
        try await task.value
    }
    private func install(_ connection: Connection) {
        store = connection.store; legacyCounts = connection.legacy; migrationBackupURL = connection.store.migrationBackupURL
        state = acceptsWork ? .ready : .closing; issues.removeValue(forKey: "open")
    }
    public func prepareConnection() async -> Bool {
        do { try await connect(); return true }
        catch { return false } // connect records the original diagnostic in observable state.
    }
    public func run<T: Sendable>(_ operation: String,
                                work: @Sendable (HistoryStore) async throws -> T) async throws -> T {
        guard acceptsWork else { throw HistoryError.unavailable }
        activeRuns += 1
        defer {
            activeRuns -= 1
            if activeRuns == 0 { let waiters = idleWaiters; idleWaiters.removeAll(); for waiter in waiters { waiter.resume() } }
        }
        try await connect()
        guard let store else { throw HistoryError.unavailable }
        do {
            let result = try await work(store)
            issues.removeValue(forKey: operation)
            return result
        } catch {
            report(error, operation: operation)
            throw error
        }
    }
    public func report(_ error: Error, operation: String) {
        issues[operation] = .init(id: operation, message: error.localizedDescription)
    }
    /// Live runners and startup recovery commit the same durable UUID. Their
    /// write failures therefore share one operation, separate from reads.
    public func recordMeasurement(_ record: MeasurementJobRecord) async throws -> MeasurementHistoryReceipt {
        let receipt = try await run("measurement.record:" + record.id.uuidString) { try await $0.recordMeasurement(record) }
        // A previously failed lookup is resolved only by executing that read
        // again. A new read failure remains visible even after a valid commit.
        if issues["measurement.lookup:" + record.id.uuidString] != nil {
            _ = try? await measurementRecord(id: record.id)
        }
        return receipt
    }
    public func measurementRecord(id: UUID) async throws -> MeasurementJobRecord? {
        try await run("measurement.lookup:" + id.uuidString) { try await $0.measurementRecord(id: id) }
    }
    /// Stop admissions first, then await the opener and every accepted body.
    /// A reference held by a caller cannot silently reopen this connection.
    public func shutdown() async throws {
        if let closing { try await closing.value; return }
        if state == .closed { return }
        acceptsWork = false; state = .closing
        let task = Task { @MainActor [self] in
            defer { closing = nil }
            if let connecting { _ = try? await connecting.value }
            if activeRuns > 0 { await withCheckedContinuation { idleWaiters.append($0) } }
            do {
                if let store { try await store.close() }
                store = nil; state = .closed; issues.removeValue(forKey: "close")
            } catch {
                state = .unavailable; report(error, operation: "close"); throw error
            }
        }
        closing = task
        try await task.value
    }
    /// Used only after a cancelled/failed app shutdown has fully drained.
    public func resumeAfterShutdown() throws {
        guard closing == nil, activeRuns == 0 else { throw HistoryError.unavailable }
        acceptsWork = true; state = store == nil ? .idle : .ready
    }
}

/// File writes expose failure to callers; no success flag is returned before
/// Foundation's atomic write has completed.
public enum ReportDocumentWriter {
    public static func write(_ report: String, to url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        try Data(report.utf8).write(to: url, options: .atomic)
    }
}
