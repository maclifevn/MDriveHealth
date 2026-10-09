/* Persistable run/log identity and completion transitions.
 * MDriveHealth, GPL-3.0-or-later. */
import Foundation

public enum SelfTestRunKind: String, Codable, Sendable { case short, extended, observed }
public enum SelfTestRunPhase: String, Codable, Sendable { case prepared, commandPending, accepted, observed }
public enum SelfTestCompletionOutcome: String, Codable, Sendable { case passed, failed, aborted, indeterminate }
public enum SelfTestCompletionSource: String, Codable, Sendable { case requested, commandUnconfirmed, observed, external }
public enum SelfTestIndeterminateReason: String, Codable, Sendable { case logReset, ambiguousLogChange, unknownResult }
public struct SelfTestRun: Sendable, Codable, Hashable {
    public let id: UUID
    public let kind: SelfTestRunKind
    public let preparedAt: Date
    public private(set) var phase: SelfTestRunPhase
    public private(set) var acceptedAt: Date?
    public let baseline: ATASelfTestLog
    fileprivate init(id: UUID, kind: SelfTestRunKind, preparedAt: Date, phase: SelfTestRunPhase, baseline: ATASelfTestLog) {
        self.id = id; self.kind = kind; self.preparedAt = preparedAt; self.phase = phase; self.baseline = baseline
    }
    fileprivate mutating func changePhase(_ phase: SelfTestRunPhase, acceptedAt: Date? = nil) {
        self.phase = phase; self.acceptedAt = acceptedAt
    }
    fileprivate func validate() throws {
        try baseline.validate()
        guard preparedAt.timeIntervalSince1970.isFinite, preparedAt >= baseline.capturedAt,
              acceptedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= preparedAt }) ?? true,
              (phase == .accepted) == (acceptedAt != nil), phase != .prepared || kind != .observed else {
            throw HistoryError.invalidData("self-test run")
        }
        guard (phase == .observed) == (kind == .observed) else { throw HistoryError.invalidData("self-test run kind/phase") }
    }
}
public struct SelfTestCompletion: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let driveKey: String
    public let model: String
    public let runID: UUID?
    public let createdAt: Date
    public let outcome: SelfTestCompletionOutcome
    public let source: SelfTestCompletionSource
    public let entry: ATASelfTestLogEntry?
    public let reason: SelfTestIndeterminateReason?
    fileprivate static func outcome(_ entry: ATASelfTestLogEntry) -> SelfTestCompletionOutcome {
        if entry.statusCode == 0 { return .passed }
        if entry.wasAborted { return .aborted }
        if (3...8).contains(entry.statusCode) { return .failed }
        return .indeterminate
    }
    public func validate() throws {
        guard !driveKey.isEmpty, driveKey.utf8.count <= 512, !driveKey.utf8.contains(0),
              model.utf8.count <= 1024, !model.utf8.contains(0), createdAt.timeIntervalSince1970.isFinite,
              (outcome == .indeterminate) == (reason != nil),
              (source == .external ? runID == nil : (runID == id)) else { throw HistoryError.invalidData("self-test event") }
        if let entry {
            guard let slot = entry.physicalSlot, (1...21).contains(slot), (1...21).contains(entry.index), !entry.inProgress,
                  entry.powerOnHours <= UInt16.max,
                  entry.failingLBA.map({ $0 <= UInt32.max && entry.statusCode == 7 }) ?? true,
                  Self.outcome(entry) == outcome else { throw HistoryError.invalidData("self-test result") }
        } else if outcome != .indeterminate { throw HistoryError.invalidData("self-test result missing") }
    }
}
public struct SelfTestTrackingState: Sendable, Codable, Hashable {
    public let version: Int
    public let driveKey: String
    public let model: String
    public private(set) var lastLog: ATASelfTestLog?
    public private(set) var activeRun: SelfTestRun?
    public private(set) var generation: UInt64
    public init(driveKey: String, model: String) throws {
        version = 1; self.driveKey = driveKey; self.model = model; generation = 0
        try validate()
    }
    public func validate() throws {
        guard version == 1, !driveKey.isEmpty, driveKey.utf8.count <= 512, !driveKey.utf8.contains(0),
              model.utf8.count <= 1024, !model.utf8.contains(0) else { throw HistoryError.invalidData("self-test state") }
        try lastLog?.validate(); try activeRun?.validate()
        if let run = activeRun {
            guard let lastLog, lastLog.capturedAt >= run.baseline.capturedAt else { throw HistoryError.invalidData("self-test run baseline") }
        }
    }
    /// Persist this prepared state before dispatch. commandPending is persisted
    /// immediately before dispatch; accepted is persisted only after ACK.
    public mutating func prepare(kind: SelfTestRunKind, baseline: ATASelfTestLog, at: Date, runID: UUID = UUID()) throws {
        try validate(); try baseline.validate()
        guard activeRun == nil, kind != .observed, baseline.latest?.inProgress != true,
              at.timeIntervalSince1970.isFinite, at >= baseline.capturedAt else { throw HistoryError.invalidData("self-test preflight/run conflict") }
        if let lastLog {
            guard baseline.capturedAt >= lastLog.capturedAt, baseline.sameContents(as: lastLog) else {
                throw HistoryError.invalidData("observe fresh preflight log before preparing a run")
            }
        }
        activeRun = .init(id: runID, kind: kind, preparedAt: at, phase: .prepared, baseline: baseline)
        lastLog = baseline
    }
    public mutating func markCommandPending(runID: UUID) throws {
        try validate()
        guard activeRun?.id == runID, activeRun?.phase == .prepared else { throw HistoryError.invalidData("self-test dispatch transition") }
        activeRun?.changePhase(.commandPending)
    }
    public mutating func markAccepted(runID: UUID, at: Date) throws {
        try validate()
        guard activeRun?.id == runID, activeRun?.phase == .commandPending,
              let run = activeRun, at.timeIntervalSince1970.isFinite, at >= run.preparedAt else { throw HistoryError.invalidData("self-test acknowledgement transition") }
        activeRun?.changePhase(.accepted, acceptedAt: at)
    }
    /// A typed "command was not issued" failure can clear a prepared/pending
    /// intent. Uncertain RPC failures must retain commandPending for recovery.
    public mutating func rejectNotIssued(runID: UUID) throws {
        try validate()
        guard activeRun?.id == runID, activeRun?.phase == .prepared || activeRun?.phase == .commandPending else {
            throw HistoryError.invalidData("self-test rejection transition")
        }
        activeRun = nil
    }
    public mutating func observe(log: ATASelfTestLog, status: ATASelfTestStatus?) throws -> [SelfTestCompletion] {
        try validate(); try log.validate()
        if let status {
            guard status.statusCode <= 8 || (status.inProgress && (status.percentRemaining ?? 100) <= 90) else {
                throw HistoryError.invalidData("self-test observation status")
            }
        }
        // All transitions have strong exception safety, including overflow.
        var next = self
        let events = try next.apply(log: log, status: status)
        self = next; return events
    }
    /// Explicit user action after a fresh terminal firmware status. Closing
    /// tracking does not cancel firmware or manufacture a pass/fail result.
    public mutating func finishWithoutResult(log: ATASelfTestLog, status: ATASelfTestStatus?) throws -> [SelfTestCompletion] {
        try validate(); try log.validate()
        guard let run = activeRun, status?.inProgress == false, log.latest?.inProgress != true,
              log.capturedAt > (lastLog?.capturedAt ?? run.preparedAt),
              log.capturedAt >= run.preparedAt else { throw HistoryError.invalidData("fresh terminal self-test status required") }
        var next = self
        var events = try next.observe(log: log, status: status)
        if let remaining = next.activeRun {
            if remaining.phase == .prepared { try next.rejectNotIssued(runID: remaining.id) }
            else {
                events.append(try next.event(log: log, entry: nil, run: remaining, reason: .unknownResult))
                next.activeRun = nil
            }
        }
        self = next; return events
    }
    private func newEntries(in log: ATASelfTestLog, since baseline: ATASelfTestLog) -> [ATASelfTestLogEntry] {
        guard log.mostRecentSlot != 0 else { return [] }
        if baseline.mostRecentSlot == 0 { return Array(log.entries.reversed()) }
        let distance = (log.mostRecentSlot - baseline.mostRecentSlot + 21) % 21
        if distance > 0 { return Array(log.entries.filter { $0.index <= distance }.reversed()) }
        if let latest = log.latest, !log.sameRecord(as: baseline.latest, entry: latest) { return [latest] }
        return []
    }
    private mutating func event(log: ATASelfTestLog, entry: ATASelfTestLogEntry?, run: SelfTestRun?,
                                reason: SelfTestIndeterminateReason? = nil) throws -> SelfTestCompletion {
        let (generation, overflow) = self.generation.addingReportingOverflow(1)
        guard !overflow else { throw HistoryError.invalidData("self-test generation overflow") }
        let outcome = entry.map(SelfTestCompletion.outcome) ?? .indeterminate
        let source: SelfTestCompletionSource
        switch run?.phase {
        case .accepted: source = .requested
        case .observed: source = .observed
        case .commandPending: source = .commandUnconfirmed
        default: source = .external
        }
        let event = SelfTestCompletion(id: run?.id ?? UUID(), driveKey: driveKey, model: model, runID: run?.id,
            createdAt: log.capturedAt, outcome: outcome, source: source, entry: entry,
            reason: outcome == .indeterminate ? (reason ?? .unknownResult) : nil)
        try event.validate(); self.generation = generation; return event
    }
    private mutating func apply(log: ATASelfTestLog, status: ATASelfTestStatus?) throws -> [SelfTestCompletion] {
        if let previous = lastLog, log.capturedAt <= previous.capturedAt { return [] }
        let previous = lastLog
        var events: [SelfTestCompletion] = [], completedSlot: Int?
        if let run = activeRun, run.phase != .prepared, log.capturedAt >= run.preparedAt {
            let baseline = run.baseline
            let slot = baseline.latest?.inProgress == true ? baseline.mostRecentSlot : baseline.mostRecentSlot % 21 + 1
            let candidates = newEntries(in: log, since: baseline)
            let candidate = baseline.latest?.inProgress == true
                ? log.entries.first(where: { $0.physicalSlot == slot && $0.testType == baseline.latest?.testType && !log.sameRecord(as: baseline.latest, entry: $0) })
                : candidates.first(where: { $0.physicalSlot == slot })
            if let candidate, !candidate.inProgress,
               (run.kind == .observed || (candidate.testType & 0x7f) == (run.kind == .short ? 1 : 2)) {
                events.append(try event(log: log, entry: candidate, run: run)); completedSlot = slot; activeRun = nil
            } else if status?.inProgress == false, !log.sameContents(as: baseline) {
                events.append(try event(log: log, entry: nil, run: run,
                                        reason: log.mostRecentSlot == 0 ? .logReset : .ambiguousLogChange))
                activeRun = nil
            }
        }
        if let previous {
            for entry in newEntries(in: log, since: previous) where !entry.inProgress && entry.physicalSlot != completedSlot {
                // The prepared command has not been dispatched; a new result
                // is external and must not be claimed as its completion.
                events.append(try event(log: log, entry: entry, run: nil))
            }
        }
        if activeRun == nil, status?.inProgress == true || log.latest?.inProgress == true {
            activeRun = .init(id: UUID(), kind: .observed, preparedAt: log.capturedAt, phase: .observed, baseline: log)
        }
        lastLog = log
        return events
    }
}
