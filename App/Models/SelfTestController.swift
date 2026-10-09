/* Durable per-drive self-test state. MDriveHealth, GPL-3.0-or-later. */
import Foundation
import Observation
import MDriveHealthCore

@MainActor @Observable final class SelfTestController {
    private(set) var states: [String: StoredSelfTestState] = [:]
    private(set) var logs: [String: ATASelfTestLog] = [:]
    private(set) var readings: [String: ATASMARTReading] = [:]
    private(set) var latestCompletions: [String: SelfTestCompletion] = [:]
    private(set) var issues: [String: String] = [:]
    private(set) var busy: Set<String> = []
    let history: HistoryAccess
    init(history: HistoryAccess) { self.history = history }

    func begin(_ key: String) throws {
        guard busy.insert(key).inserted else { throw DriveOperationError.busy }
    }
    func end(_ key: String) { busy.remove(key) }
    func report(_ error: Error, key: String) { issues[key] = error.localizedDescription }
    func restore(key: String, model: String) async throws {
        _ = try await load(key: key, model: model)
        let latest = try await history.run("selfTest.latest:" + key) { try await $0.latestSelfTestEvent(driveKey: key) }
        latestCompletions[key] = latest?.event
    }
    func retainAttachedKeys(_ keys: Set<String>) {
        states = states.filter { keys.contains($0.key) || busy.contains($0.key) }
        logs = logs.filter { keys.contains($0.key) || busy.contains($0.key) }
        readings = readings.filter { keys.contains($0.key) || busy.contains($0.key) }
        latestCompletions = latestCompletions.filter { keys.contains($0.key) || busy.contains($0.key) }
        issues = issues.filter { keys.contains($0.key) || busy.contains($0.key) }
    }
    private func load(key: String, model: String) async throws -> StoredSelfTestState? {
        let stored = try await history.run("selfTest.load:" + key) { try await $0.selfTestState(driveKey: key) }
        guard stored.map({ $0.state.model == model }) ?? true else { throw HardwareWorkerError.deviceChanged }
        if let stored { states[key] = stored; if logs[key] == nil { logs[key] = stored.state.lastLog } }
        else { states.removeValue(forKey: key) }
        return stored
    }
    private func commit(_ state: SelfTestTrackingState, revision: Int64, events: [SelfTestCompletion] = []) async throws -> StoredSelfTestState {
        let stored = try await history.run("selfTest.save:" + state.driveKey) {
            try await $0.commitSelfTest(state, expectedRevision: revision, events: events)
        }
        states[state.driveKey] = stored; issues.removeValue(forKey: state.driveKey)
        logs[state.driveKey] = state.lastLog
        if let latest = events.last { latestCompletions[state.driveKey] = latest }
        return stored
    }
    /// Call only after full fleet identity resolution and while owning the
    /// per-drive operation. A prepared intent is safe to clear on recovery:
    /// dispatch is forbidden until commandPending has committed.
    func observe(key: String, model: String, observation: SelfTestObservation) async throws {
        try observation.validate(); logs[key] = observation.log; readings[key] = observation.reading
        let previous = try await load(key: key, model: model)
        var state = try previous?.state ?? SelfTestTrackingState(driveKey: key, model: model)
        if let run = state.activeRun, run.phase == .prepared { try state.rejectNotIssued(runID: run.id) }
        let events = try state.observe(log: observation.log, status: observation.reading.selfTest)
        if state != previous?.state { _ = try await commit(state, revision: previous?.revision ?? 0, events: events) }
        issues.removeValue(forKey: key)
    }
    func prepare(key: String, model: String, kind: SelfTestRunKind, baseline: ATASelfTestLog) async throws -> SelfTestCommand {
        let previous = try await load(key: key, model: model)
        var state = try previous?.state ?? SelfTestTrackingState(driveKey: key, model: model)
        try state.prepare(kind: kind, baseline: baseline, at: Date())
        let run = state.activeRun!
        _ = try await commit(state, revision: previous?.revision ?? 0)
        return .init(runID: run.id, driveKey: key, kind: kind, baseline: baseline)
    }
    func markPending(_ command: SelfTestCommand, model: String) async throws {
        guard let previous = try await load(key: command.driveKey, model: model) else { throw HistoryError.unavailable }
        var state = previous.state; try state.markCommandPending(runID: command.runID)
        _ = try await commit(state, revision: previous.revision)
    }
    func markAccepted(_ command: SelfTestCommand, receipt: SelfTestReceipt, model: String) async throws {
        guard receipt.runID == command.runID,
              let previous = try await load(key: command.driveKey, model: model) else { throw HardwareWorkerError.protocolViolation }
        var state = previous.state; try state.markAccepted(runID: command.runID, at: receipt.acceptedAt)
        _ = try await commit(state, revision: previous.revision)
    }
    func reject(_ command: SelfTestCommand, model: String) async throws {
        guard let previous = try await load(key: command.driveKey, model: model) else { throw HistoryError.unavailable }
        var state = previous.state; try state.rejectNotIssued(runID: command.runID)
        _ = try await commit(state, revision: previous.revision)
    }
    func finishWithoutResult(key: String, model: String, observation: SelfTestObservation) async throws {
        try observation.validate()
        guard let previous = try await load(key: key, model: model) else { throw HistoryError.unavailable }
        var state = previous.state
        let events = try state.finishWithoutResult(log: observation.log, status: observation.reading.selfTest)
        _ = try await commit(state, revision: previous.revision, events: events)
        readings[key] = observation.reading
    }
}
