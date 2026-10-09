/* App measurement boundary and bounded MainActor publication. GPL-3.0-or-later. */
import Foundation
import MDriveHealthCore

struct MeasurementWorkspaceReview: Sendable, Identifiable {
    let id: UUID
    let drive: DriveInfo
    let volume: VolumeUsage
    let message: String
    let writeDirectoryPath: String
    let origin: MeasurementOrigin
    init(id: UUID, drive: DriveInfo, volume: VolumeUsage, message: String, writeDirectoryPath: String? = nil, origin: MeasurementOrigin? = nil) {
        self.id = id; self.drive = drive; self.volume = volume; self.message = message
        self.writeDirectoryPath = writeDirectoryPath ?? DiskWorkspaceRecovery.writeDirectoryPath(for: volume)
        self.origin = origin ?? MeasurementOrigin(drive: drive)
    }
}
struct MeasurementJournalIssue: Sendable {
    let driveKey: String
    let message: String
}

protocol MeasurementServing: Sendable {
    func prepareJournal(_ intent: MeasurementJobIntent) async throws -> MeasurementJobLease?
    func discardJournal(_ receipt: MeasurementHistoryReceipt) async throws
    func benchmark(drive: DriveInfo, volume: VolumeUsage, config: BenchmarkConfig, id: UUID, lease: DriveCommandLock.Lease,
                   cancelled: @escaping @Sendable () -> Bool, progress: @escaping DiskBenchmarkEngine.ProgressHandler,
                   cleaning: @escaping @Sendable (Int) -> Void) async throws -> BenchmarkResult
    func capacity(drive: DriveInfo, volume: VolumeUsage, config: CapacityVerifyConfig, id: UUID, lease: DriveCommandLock.Lease,
                  cancelled: @escaping @Sendable () -> Bool, progress: @escaping CapacityVerifier.ProgressHandler,
                  cleaning: @escaping @Sendable (Int) -> Void) async throws -> CapacityVerifyResult
    func benchmark(drive: DriveInfo, volume: VolumeUsage, config: BenchmarkConfig, id: UUID, lease: DriveCommandLock.Lease, job: MeasurementJobLease?,
                   cancelled: @escaping @Sendable () -> Bool, progress: @escaping DiskBenchmarkEngine.ProgressHandler,
                   cleaning: @escaping @Sendable (Int) -> Void) async throws -> BenchmarkResult
    func capacity(drive: DriveInfo, volume: VolumeUsage, config: CapacityVerifyConfig, id: UUID, lease: DriveCommandLock.Lease, job: MeasurementJobLease?,
                  cancelled: @escaping @Sendable () -> Bool, progress: @escaping CapacityVerifier.ProgressHandler,
                  cleaning: @escaping @Sendable (Int) -> Void) async throws -> CapacityVerifyResult
}
extension MeasurementServing {
    // Explicit old fixture providers do not touch the user's journal. A
    // provider that opts into journaling must implement the job-aware call.
    func prepareJournal(_ intent: MeasurementJobIntent) async throws -> MeasurementJobLease? { nil }
    func discardJournal(_ receipt: MeasurementHistoryReceipt) async throws {}
    func benchmark(drive: DriveInfo, volume: VolumeUsage, config: BenchmarkConfig, id: UUID, lease: DriveCommandLock.Lease, job: MeasurementJobLease?,
                   cancelled: @escaping @Sendable () -> Bool, progress: @escaping DiskBenchmarkEngine.ProgressHandler,
                   cleaning: @escaping @Sendable (Int) -> Void) async throws -> BenchmarkResult {
        guard job == nil else { throw MeasurementWorkerError.protocolViolation }
        return try await benchmark(drive: drive, volume: volume, config: config, id: id, lease: lease, cancelled: cancelled, progress: progress, cleaning: cleaning)
    }
    func capacity(drive: DriveInfo, volume: VolumeUsage, config: CapacityVerifyConfig, id: UUID, lease: DriveCommandLock.Lease, job: MeasurementJobLease?,
                  cancelled: @escaping @Sendable () -> Bool, progress: @escaping CapacityVerifier.ProgressHandler,
                  cleaning: @escaping @Sendable (Int) -> Void) async throws -> CapacityVerifyResult {
        guard job == nil else { throw MeasurementWorkerError.protocolViolation }
        return try await capacity(drive: drive, volume: volume, config: config, id: id, lease: lease, cancelled: cancelled, progress: progress, cleaning: cleaning)
    }
}
struct SystemMeasurements: MeasurementServing {
    var client = MeasurementWorkerClient.bundled
    func prepareJournal(_ intent: MeasurementJobIntent) async throws -> MeasurementJobLease? { try await client.prepareJob(intent) }
    func discardJournal(_ receipt: MeasurementHistoryReceipt) async throws { try await SystemMeasurementRecovery(rootURL: client.journalRootURL).discard(receipt) }
    func benchmark(drive: DriveInfo, volume: VolumeUsage, config: BenchmarkConfig, id: UUID, lease: DriveCommandLock.Lease,
                   cancelled: @escaping @Sendable () -> Bool, progress: @escaping DiskBenchmarkEngine.ProgressHandler,
                   cleaning: @escaping @Sendable (Int) -> Void) async throws -> BenchmarkResult {
        try await client.benchmark(drive: drive, volume: volume, config: config, id: id, lease: lease, isCancelled: cancelled, progress: progress, cleaning: cleaning)
    }
    func capacity(drive: DriveInfo, volume: VolumeUsage, config: CapacityVerifyConfig, id: UUID, lease: DriveCommandLock.Lease,
                  cancelled: @escaping @Sendable () -> Bool, progress: @escaping CapacityVerifier.ProgressHandler,
                  cleaning: @escaping @Sendable (Int) -> Void) async throws -> CapacityVerifyResult {
        try await client.capacity(drive: drive, volume: volume, config: config, id: id, lease: lease, isCancelled: cancelled, progress: progress, cleaning: cleaning)
    }
    func benchmark(drive: DriveInfo, volume: VolumeUsage, config: BenchmarkConfig, id: UUID, lease: DriveCommandLock.Lease, job: MeasurementJobLease?,
                   cancelled: @escaping @Sendable () -> Bool, progress: @escaping DiskBenchmarkEngine.ProgressHandler,
                   cleaning: @escaping @Sendable (Int) -> Void) async throws -> BenchmarkResult {
        guard let job else { throw MeasurementWorkerError.protocolViolation }
        return try await client.benchmark(drive: drive, volume: volume, config: config, id: id, lease: lease, job: job, isCancelled: cancelled, progress: progress, cleaning: cleaning)
    }
    func capacity(drive: DriveInfo, volume: VolumeUsage, config: CapacityVerifyConfig, id: UUID, lease: DriveCommandLock.Lease, job: MeasurementJobLease?,
                  cancelled: @escaping @Sendable () -> Bool, progress: @escaping CapacityVerifier.ProgressHandler,
                  cleaning: @escaping @Sendable (Int) -> Void) async throws -> CapacityVerifyResult {
        guard let job else { throw MeasurementWorkerError.protocolViolation }
        return try await client.capacity(drive: drive, volume: volume, config: config, id: id, lease: lease, job: job, isCancelled: cancelled, progress: progress, cleaning: cleaning)
    }
}

func recoveredMeasurementRecord(_ error: Error) -> MeasurementJobRecord? {
    switch error as? MeasurementWorkerError {
    case .resultNotPersisted(let record, _), .resultNotDelivered(let record, _): return record
    default: return nil
    }
}
func completedMeasurementRecord(job: MeasurementJobLease, outcome: MeasurementJobOutcome) -> MeasurementJobRecord {
    if let record = job.cachedRecord(), record.terminal != nil { return record }
    // Preserve the known completed result even when a provider loses its
    // cached receipt. GC still requires an exact on-disk record/SQL receipt.
    return .init(intent: job.intent, terminal: .init(intent: job.intent, outcome: outcome))
}

/// A killed/invalid worker cannot confirm cleanup. Preserve this independently
/// of Reset until the recovery flow obtains fresh workspace evidence.
func measurementFailureNeedsWorkspaceReview(_ error: Error) -> Bool {
    if let record = recoveredMeasurementRecord(error), record.terminal?.outcome.cleanupConfirmed == false { return true }
    if case BenchmarkError.cleanupFailed = error { return true }
    if let command = error as? CommandError { return command.processID != nil }
    if case MeasurementWorkerError.protocolViolation = error { return true }
    if case MeasurementWorkerError.remote(let message) = error { return message.contains(".com.maclife.mdrivehealth.test-") }
    return false
}

/// One latest value and at most one delivery Task, even if a provider floods.
final class LatestProgress<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Value?
    private var scheduled = false
    private let receive: @MainActor @Sendable (Value) -> Void
    init(receive: @escaping @MainActor @Sendable (Value) -> Void) { self.receive = receive }
    func submit(_ value: Value) {
        lock.lock(); latest = value
        if scheduled { lock.unlock(); return }
        scheduled = true; lock.unlock()
        Task { @MainActor [self] in
            while let value = take() { receive(value); await Task.yield() }
        }
    }
    private func take() -> Value? {
        lock.lock(); defer { lock.unlock() }
        let value = latest; latest = nil
        if value == nil { scheduled = false }
        return value
    }
}
