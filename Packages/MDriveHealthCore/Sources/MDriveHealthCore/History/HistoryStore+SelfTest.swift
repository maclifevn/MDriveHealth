/* Atomic self-test ledger/outbox and compare-and-swap revisions.
 * MDriveHealth, GPL-3.0-or-later. */
import Foundation
import SQLite3

public struct StoredSelfTestState: Sendable, Equatable {
    public let revision: Int64
    public let state: SelfTestTrackingState
}
public enum SelfTestDeliveryState: String, Sendable, Codable, CaseIterable {
    case pending, sending, delivered, suppressed, uncertain
}
public struct StoredSelfTestEvent: Sendable, Equatable {
    public let event: SelfTestCompletion
    public let delivery: SelfTestDeliveryState
}
public enum SelfTestJournalError: Error, LocalizedError, Sendable {
    case revisionConflict, outboxFull
    public var errorDescription: String? {
        switch self { case .revisionConflict: return "Self-test state changed in another operation; reload before retrying"
        case .outboxFull: return "Self-test notification queue is full; review pending events" }
    }
}

extension HistoryStore {
    private func validateSelfTestKey(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 512, !key.utf8.contains(0) else { throw HistoryError.invalidData("self-test drive key") }
    }
    private func selfTestJSON<T: Encodable>(_ value: T, limit: Int) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value)
        guard bytes.count <= limit, let text = String(data: bytes, encoding: .utf8) else { throw HistoryError.invalidData("self-test JSON budget") }
        return text
    }
    private func decodeSelfTestJSON<T: Decodable>(_ type: T.Type, from statement: OpaquePointer?, index: Int32, limit: Int) throws -> T {
        let length = Int(sqlite3_column_bytes(statement, index))
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT, length > 0, length <= limit,
              let pointer = sqlite3_column_text(statement, index) else { throw HistoryError.invalidData("stored self-test JSON type/budget") }
        let bytes = Data(bytes: pointer, count: length)
        guard String(data: bytes, encoding: .utf8) != nil else { throw HistoryError.invalidData("stored self-test UTF-8") }
        do { return try JSONDecoder().decode(type, from: bytes) }
        catch { throw HistoryError.invalidData("stored self-test JSON: \(error.localizedDescription)") }
    }
    public func selfTestState(driveKey: String) throws -> StoredSelfTestState? {
        try validateSelfTestKey(driveKey)
        return try serialQueue.sync {
            let statement = try prepare("SELECT revision,state FROM self_test_tracking WHERE drive_key=?")
            defer { sqlite3_finalize(statement) }; try bindText(statement, 1, driveKey)
            let results: [StoredSelfTestState] = try rows(statement) { row in
                guard let revision = try optionalInt(row, 0), revision > 0 else { throw HistoryError.invalidData("stored self-test revision") }
                let state = try decodeSelfTestJSON(SelfTestTrackingState.self, from: row, index: 1, limit: 65_536)
                try state.validate(); guard state.driveKey == driveKey else { throw HistoryError.invalidData("stored self-test key mismatch") }
                return .init(revision: revision, state: state)
            }
            guard results.count <= 1 else { throw HistoryError.invalidData("duplicate self-test state") }
            return results.first
        }
    }
    /// The new state and its completion events commit together. A failed write
    /// cannot consume a log identity without retaining its event.
    public func commitSelfTest(_ state: SelfTestTrackingState, expectedRevision: Int64,
                               events: [SelfTestCompletion] = []) throws -> StoredSelfTestState {
        try state.validate(); try validateSelfTestKey(state.driveKey)
        guard expectedRevision >= 0, expectedRevision < Int64.max, events.count <= 22, Set(events.map(\.id)).count == events.count else {
            throw HistoryError.invalidData("self-test commit budget/revision")
        }
        let encodedState = try selfTestJSON(state, limit: 65_536)
        let encodedEvents = try events.map { event -> String in
            try event.validate()
            guard event.driveKey == state.driveKey, event.model == state.model else { throw HistoryError.invalidData("self-test event ownership") }
            return try selfTestJSON(event, limit: 8192)
        }
        return try serialQueue.sync {
            try transaction {
                let query = try prepare("SELECT revision FROM self_test_tracking WHERE drive_key=?")
                defer { sqlite3_finalize(query) }; try bindText(query, 1, state.driveKey)
                let revisions: [Int64] = try rows(query) { row in
                    guard let revision = try optionalInt(row, 0), revision > 0 else { throw HistoryError.invalidData("stored self-test revision") }
                    return revision
                }
                guard revisions.count <= 1, (revisions.first ?? 0) == expectedRevision else { throw SelfTestJournalError.revisionConflict }
                let update = try prepare("INSERT INTO self_test_tracking(drive_key,revision,state) VALUES(?,?,?) ON CONFLICT(drive_key) DO UPDATE SET revision=excluded.revision,state=excluded.state")
                defer { sqlite3_finalize(update) }
                try bindText(update, 1, state.driveKey); try bindOptionalInt(update, 2, expectedRevision + 1); try bindText(update, 3, encodedState); try done(update)
                guard sqlite3_changes(database) == 1 else { throw HistoryError.invalidData("self-test state write count") }
                for (event, encoded) in zip(events, encodedEvents) {
                    let existing = try prepare("SELECT event FROM self_test_events WHERE id=?")
                    defer { sqlite3_finalize(existing) }; try bindText(existing, 1, event.id.uuidString)
                    let duplicates: [SelfTestCompletion] = try rows(existing) { try decodeSelfTestJSON(SelfTestCompletion.self, from: $0, index: 0, limit: 8192) }
                    if let duplicate = duplicates.first {
                        guard duplicates.count == 1, duplicate == event else { throw HistoryError.invalidData("self-test event ID reused") }
                        continue
                    }
                    let insert = try prepare("INSERT INTO self_test_events(id,drive_key,created_at,event,delivery_state) VALUES(?,?,?,?,'pending')")
                    defer { sqlite3_finalize(insert) }
                    try bindText(insert, 1, event.id.uuidString); try bindText(insert, 2, event.driveKey)
                    try bindDouble(insert, 3, event.createdAt.timeIntervalSince1970); try bindText(insert, 4, encoded); try done(insert)
                }
                guard try scalarInt("SELECT COUNT(*) FROM self_test_events WHERE delivery_state IN ('pending','sending','uncertain')") <= 4096 else {
                    throw SelfTestJournalError.outboxFull
                }
            }
            return .init(revision: expectedRevision + 1, state: state)
        }
    }
    public func selfTestEvents(driveKey: String? = nil, states: [SelfTestDeliveryState]? = nil,
                              limit: Int = 4096) throws -> [StoredSelfTestEvent] {
        if let driveKey { try validateSelfTestKey(driveKey) }
        guard (1...4096).contains(limit), states.map({ !$0.isEmpty && $0.count <= 5 && Set($0).count == $0.count }) ?? true else {
            throw HistoryError.invalidData("self-test query budget")
        }
        return try serialQueue.sync {
            var clauses: [String] = []
            if driveKey != nil { clauses.append("drive_key=?") }
            if let states { clauses.append("delivery_state IN (\(Array(repeating: "?", count: states.count).joined(separator: ",")))") }
            let filter = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
            let statement = try prepare("SELECT id,drive_key,event,delivery_state,created_at FROM self_test_events" + filter + " ORDER BY created_at,rowid LIMIT ?")
            defer { sqlite3_finalize(statement) }; var index: Int32 = 1
            if let driveKey { try bindText(statement, index, driveKey); index += 1 }
            for state in states ?? [] { try bindText(statement, index, state.rawValue); index += 1 }
            try bindOptionalInt(statement, index, Int64(limit + 1))
            let results: [StoredSelfTestEvent] = try rows(statement) { row in
                let event = try decodeSelfTestJSON(SelfTestCompletion.self, from: row, index: 2, limit: 8192)
                try event.validate()
                guard text(row, 0) == event.id.uuidString, text(row, 1) == event.driveKey,
                      try requiredDouble(row, 4) == event.createdAt.timeIntervalSince1970,
                      let raw = text(row, 3), let delivery = SelfTestDeliveryState(rawValue: raw) else { throw HistoryError.invalidData("stored self-test event metadata") }
                return .init(event: event, delivery: delivery)
            }
            guard results.count <= limit else { throw HistoryError.invalidData("self-test event query limit reached") }
            guard Set(results.map { $0.event.id }).count == results.count else { throw HistoryError.invalidData("duplicate stored self-test events") }
            return results
        }
    }
    /// Sending is persisted before SDK submission. On restart it is reconciled
    /// with system request IDs or shown as uncertain; never silently resent.
    public func latestSelfTestEvent(driveKey: String) throws -> StoredSelfTestEvent? {
        try validateSelfTestKey(driveKey)
        return try serialQueue.sync {
            let statement = try prepare("SELECT id,drive_key,event,delivery_state,created_at FROM self_test_events WHERE drive_key=? ORDER BY created_at DESC,rowid DESC LIMIT 1")
            defer { sqlite3_finalize(statement) }; try bindText(statement, 1, driveKey)
            let results: [StoredSelfTestEvent] = try rows(statement) { row in
                let event = try decodeSelfTestJSON(SelfTestCompletion.self, from: row, index: 2, limit: 8192)
                try event.validate()
                guard text(row, 0) == event.id.uuidString, text(row, 1) == event.driveKey, event.driveKey == driveKey,
                      try requiredDouble(row, 4) == event.createdAt.timeIntervalSince1970,
                      let raw = text(row, 3), let delivery = SelfTestDeliveryState(rawValue: raw) else { throw HistoryError.invalidData("stored self-test event metadata") }
                return .init(event: event, delivery: delivery)
            }
            return results.first
        }
    }
    @discardableResult public func transitionSelfTestEvent(id: UUID, from: SelfTestDeliveryState,
                                                          to: SelfTestDeliveryState) throws -> Bool {
        let allowed: [SelfTestDeliveryState: Set<SelfTestDeliveryState>] = [
            .pending: [.sending,.suppressed], .sending: [.pending,.delivered,.uncertain,.suppressed],
            .uncertain: [.pending,.delivered,.suppressed]]
        guard from == to || allowed[from]?.contains(to) == true else { throw HistoryError.invalidData("self-test delivery transition") }
        return try serialQueue.sync {
            let statement = try prepare("UPDATE self_test_events SET delivery_state=? WHERE id=? AND delivery_state=?")
            defer { sqlite3_finalize(statement) }
            try bindText(statement, 1, to.rawValue); try bindText(statement, 2, id.uuidString); try bindText(statement, 3, from.rawValue)
            try done(statement); return sqlite3_changes(database) == 1
        }
    }
    public func selfTestState(driveKey: String) async throws -> StoredSelfTestState? {
        try await offMain { try self.selfTestState(driveKey: driveKey) }
    }
    public func commitSelfTest(_ state: SelfTestTrackingState, expectedRevision: Int64,
                               events: [SelfTestCompletion] = []) async throws -> StoredSelfTestState {
        try await offMain { try self.commitSelfTest(state, expectedRevision: expectedRevision, events: events) }
    }
    public func selfTestEvents(driveKey: String? = nil, states: [SelfTestDeliveryState]? = nil,
                              limit: Int = 4096) async throws -> [StoredSelfTestEvent] {
        try await offMain { try self.selfTestEvents(driveKey: driveKey, states: states, limit: limit) }
    }
    public func latestSelfTestEvent(driveKey: String) async throws -> StoredSelfTestEvent? {
        try await offMain { try self.latestSelfTestEvent(driveKey: driveKey) }
    }
    @discardableResult public func transitionSelfTestEvent(id: UUID, from: SelfTestDeliveryState,
                                                          to: SelfTestDeliveryState) async throws -> Bool {
        try await offMain { try self.transitionSelfTestEvent(id: id, from: from, to: to) }
    }
}
