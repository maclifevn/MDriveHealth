/* Startup journal recovery and offline measurement history. GPL-3.0-or-later. */
import Foundation
import Observation
import MDriveHealthCore
import Darwin

struct RecoveredMeasurement: Sendable, Identifiable {
    let id: String
    var state: MeasurementRecoveredJob.State
    var intent: MeasurementJobIntent?
    var journalRecord: MeasurementJobRecord?
    var record: MeasurementJobRecord?
    var cleanupConfirmed = false
    var archived = false
    var issue: String?
}
struct MeasurementRecoveryScan: Sendable {
    var jobs: [RecoveredMeasurement]
    let unknownEntries: [String]
}
protocol MeasurementRecovering: Sendable {
    func scan() async throws -> MeasurementRecoveryScan
    func restoreTerminal(_ record: MeasurementJobRecord) async throws -> Bool
    func discard(_ receipt: MeasurementHistoryReceipt) async throws
    func discardOmitted(_ record: MeasurementJobRecord) async throws
    func confirmCleanup(_ record: MeasurementJobRecord, proof: WorkspaceRecoveryProof) async throws
}
private func sameMeasurementIntent(_ a: MeasurementJobIntent, _ b: MeasurementJobIntent) throws -> Bool {
    try MeasurementJobRecord(intent: a, terminal: nil).recordSHA256 == MeasurementJobRecord(intent: b, terminal: nil).recordSHA256
}
struct SystemMeasurementRecovery: MeasurementRecovering {
    var rootURL: URL?
    private func root() throws -> MeasurementJournal {
        try MeasurementJournal(rootURL: rootURL ?? MeasurementJournal.defaultRootURL())
    }
    func scan() async throws -> MeasurementRecoveryScan {
        try await Task.detached(priority: .utility) {
            let root = try root(), scan = try root.scan()
            var jobs: [RecoveredMeasurement] = []
            for job in scan.jobs {
                var row = RecoveredMeasurement(id: job.name, state: job.state, issue: job.diagnostic)
                // A live child retains the job lock after parent death.
                // Never inspect mutable files or classify that run interrupted.
                if job.state == .active { jobs.append(row); continue }
                let id: UUID?
                if job.name.hasPrefix("job-") { id = UUID(uuidString: String(job.name.dropFirst(4))) }
                else if job.name.hasPrefix("receipt-"), job.name.hasSuffix(".json") { id = UUID(uuidString: String(job.name.dropFirst(8).dropLast(5))) }
                else { id = nil }
                guard let id else { jobs.append(row); continue }
                do {
                    if job.state == .acknowledged { try root.collectAcknowledged(id: id); continue }
                    let lease = try root.openJob(id: id)
                    row.intent = lease.intent
                    // Promote only a single intact terminal before archiving
                    // an interrupted attempt. Torn/foreign metadata stays put.
                    try lease.recoverStagedTerminal()
                    let record = try lease.record()
                    row.journalRecord = record; row.record = record
                    row.cleanupConfirmed = try lease.cleanupConfirmed()
                    row.state = record.terminal == nil ? .interrupted : .completed
                    row.issue = nil
                } catch MeasurementJournalError.busy {
                    row.state = .active; row.intent = nil; row.record = nil; row.journalRecord = nil; row.issue = nil
                } catch { row.state = .unverified; row.issue = error.localizedDescription }
                jobs.append(row)
            }
            return MeasurementRecoveryScan(jobs: jobs, unknownEntries: scan.unknownEntries)
        }.value
    }
    func restoreTerminal(_ record: MeasurementJobRecord) async throws -> Bool {
        try await Task.detached(priority: .utility) {
            let root = try root(), lease = try root.openJob(id: record.id)
            guard try sameMeasurementIntent(lease.intent, record.intent), let terminal = record.terminal else { throw MeasurementJournalError.receiptMismatch }
            try lease.recoverStagedTerminal()
            let current = try lease.record()
            if current.terminal == nil { try lease.writeTerminal(terminal) }
            guard try lease.record().recordSHA256 == record.recordSHA256 else { throw MeasurementJournalError.receiptMismatch }
            return try lease.cleanupConfirmed()
        }.value
    }
    func discard(_ receipt: MeasurementHistoryReceipt) async throws {
        try await Task.detached(priority: .utility) {
            let root = try root()
            do { try root.discardCommitted(receipt) }
            catch let error as MeasurementJournalError {
                // Another importer or the live runner can finish the same
                // UUID's GC first. Absence means there is no metadata left
                // to remove; it never proves workspace cleanup on its own.
                guard case .io(_, ENOENT) = error else { throw error }
                let scan = try root.scan()
                let names = ["job-" + receipt.id.uuidString, "receipt-" + receipt.id.uuidString + ".json"]
                guard !scan.jobs.contains(where: { names.contains($0.name) }), !scan.unknownEntries.contains(where: names.contains) else { throw error }
            }
        }.value
    }
    func discardOmitted(_ record: MeasurementJobRecord) async throws {
        try await Task.detached(priority: .utility) { try root().discardOmitted(id: record.id, recordSHA256: record.recordSHA256) }.value
    }
    func confirmCleanup(_ record: MeasurementJobRecord, proof: WorkspaceRecoveryProof) async throws {
        try await Task.detached(priority: .utility) {
            let root = try root(), lease = try root.openJob(id: record.id)
            guard try lease.record().recordSHA256 == record.recordSHA256 else { throw MeasurementJournalError.changed }
            try lease.confirmCleanup(currentOrigin: proof.origin, currentVolume: proof.volume, scan: proof.scan)
        }.value
    }
}

@MainActor @Observable final class MeasurementRecoveryController {
    static let pageSize = 100
    private(set) var jobs: [RecoveredMeasurement] = []
    private(set) var unknownEntries: [String] = []
    private(set) var archivedRecords: [MeasurementJobRecord] = []
    private(set) var issue: String?
    private(set) var showingOlderPage = false
    private(set) var started = false
    private(set) var isBusy = false
    private let history: HistoryAccess
    private let service: any MeasurementRecovering
    private var suspended = false
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored var onNeedsWorkspaceScan: (() -> Void)?
    init(history: HistoryAccess, service: any MeasurementRecovering = SystemMeasurementRecovery()) {
        self.history = history; self.service = service
    }
    var hasAttention: Bool { issue != nil || !unknownEntries.isEmpty || !jobs.isEmpty }
    var canLoadOlder: Bool { archivedRecords.count == Self.pageSize }
    var workspaceReviews: [MeasurementWorkspaceReview] {
        jobs.compactMap { row in
            guard row.state != .active, !row.cleanupConfirmed, let record = row.journalRecord, let origin = record.intent.origin else { return nil }
            let intent = record.intent
            return .init(id: intent.id, drive: intent.drive, volume: intent.volume,
                message: String(localized: "measurementHistory.cleanupPending", defaultValue: "Phiên cũ chưa xác nhận dọn file test. Cần quét lại đúng ổ và thư mục trước khi đóng hồ sơ phục hồi."),
                writeDirectoryPath: intent.writeDirectoryPath, origin: origin)
        }
    }
    // Production explicitly starts recovery. Constructing model fixtures never
    // reads or mutates the user's Application Support journal.
    func start() { guard !started else { return }; started = true; requestRefresh() }
    func requestRefresh() {
        guard started, !suspended else { return }
        refreshRequested = true
        guard !refreshQueued else { return }
        refreshQueued = true
        enqueue { [self] in
            repeat { refreshRequested = false; await refresh() } while refreshRequested && !suspended
            refreshQueued = false
        }
    }
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID(), previous = tail
        isBusy = true
        let task = Task { @MainActor [self] in
            if let previous { await previous.value }
            await work()
            tasks.removeValue(forKey: id)
            isBusy = !tasks.isEmpty
            if tasks.isEmpty { tail = nil }
        }
        tasks[id] = task; tail = task
    }
    private func refresh() async {
        let previousReviews = Set(workspaceReviews.map(\.id))
        do {
            let scan = try await service.scan()
            unknownEntries = scan.unknownEntries
            var retained: [RecoveredMeasurement] = []
            for var row in scan.jobs {
                guard row.state != .active, let intent = row.intent, intent.historyPolicy != .omit else { retained.append(row); continue }
                do {
                    let existing = try await history.measurementRecord(id: intent.id)
                    if let existing {
                        guard try sameMeasurementIntent(existing.intent, intent) else { throw MeasurementJournalError.receiptMismatch }
                        if row.journalRecord?.terminal == nil, row.journalRecord != nil, existing.terminal != nil {
                            // SQL can hold the durable result when metadata
                            // publication failed. Restore only the exact intent,
                            // under the exclusive job lease, without overwrite.
                            row.record = existing; row.archived = true
                            row.cleanupConfirmed = try await service.restoreTerminal(existing)
                            row.journalRecord = existing; row.state = .completed
                        } else if let record = row.journalRecord {
                            guard try existing.recordSHA256 == record.recordSHA256 else { throw MeasurementJournalError.receiptMismatch }
                        } else {
                            row.record = existing; row.archived = true
                            retained.append(row); continue // Unknown metadata is preserved.
                        }
                    }
                    guard let record = row.journalRecord else { retained.append(row); continue }
                    let receipt = try await history.recordMeasurement(record)
                    row.archived = true
                    if row.cleanupConfirmed { try await service.discard(receipt); continue }
                } catch { row.issue = error.localizedDescription }
                retained.append(row)
            }
            jobs = retained; issue = nil
        } catch { issue = error.localizedDescription } // Keep the previous catalog on scan failure.
        await loadPage(before: nil)
        if !Set(workspaceReviews.map(\.id)).subtracting(previousReviews).isEmpty { onNeedsWorkspaceScan?() }
    }
    private func loadPage(before: MeasurementHistoryCursor?) async {
        do {
            archivedRecords = try await history.run("measurement.history") { try await $0.measurementRecords(limit: Self.pageSize, before: before) }
            showingOlderPage = before != nil
        } catch { issue = error.localizedDescription } // Previous results remain visible.
    }
    func loadOlder() {
        guard started, !suspended, !isBusy, canLoadOlder, let last = archivedRecords.last else { return }
        let cursor = MeasurementHistoryCursor(createdAt: last.intent.createdAt, id: last.id)
        enqueue { await self.loadPage(before: cursor) }
    }
    func discardOmitted(_ selected: MeasurementJobRecord) {
        let id = "job-" + selected.id.uuidString
        guard !suspended, !isBusy, let row = jobs.first(where: { $0.id == id }), let record = row.journalRecord,
              (try? record.recordSHA256) == (try? selected.recordSHA256),
              record.intent.historyPolicy == .omit, record.terminal != nil, row.cleanupConfirmed else { return }
        enqueue {
            do { try await self.service.discardOmitted(record); self.jobs.removeAll { $0.id == id } }
            catch { self.issue = error.localizedDescription }
        }
    }
    func reconcile(_ evidence: WorkspaceRecoveryEvidence) {
        guard started, !suspended else { return }
        let proofs = workspaceReviews.compactMap { review -> (MeasurementJobRecord, WorkspaceRecoveryProof)? in
            guard let proof = evidence.proofConfirmingAbsence(of: review), let record = jobs.first(where: { $0.intent?.id == review.id })?.journalRecord else { return nil }
            return (record, proof)
        }
        guard !proofs.isEmpty else { return }
        enqueue {
            for (record, proof) in proofs {
                do { try await self.service.confirmCleanup(record, proof: proof) }
                catch { self.issue = error.localizedDescription }
            }
            await self.refresh()
        }
    }
    func beginShutdown() { suspended = true }
    func waitForCompletion() async { while !tasks.isEmpty { for task in Array(tasks.values) { await task.value } } }
    func resumeAfterShutdown() { suspended = false; requestRefresh() }
}
